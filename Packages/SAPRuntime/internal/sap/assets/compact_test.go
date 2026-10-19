package assets

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// These are synthetic Mach-O images, not copies of Apple's components. Put a
// different ARM64 subtype before arm64e to detect an incorrect slice choice.
func universalFixture(marker byte) ([]byte, []byte) {
	architectures := [][2]uint32{{0x01000007, 3}, {0x0100000c, 0x8000000c}, {0x0100000c, 0x80000002}}
	const imageSize = 48
	const headerSize = 8 + 3*20
	data := make([]byte, headerSize+len(architectures)*imageSize)
	binary.BigEndian.PutUint32(data, 0xcafebabe)
	binary.BigEndian.PutUint32(data[4:], uint32(len(architectures)))
	for index, architecture := range architectures {
		offset := headerSize + index*imageSize
		header := data[8+index*20:]
		binary.BigEndian.PutUint32(header, architecture[0])
		binary.BigEndian.PutUint32(header[4:], architecture[1])
		binary.BigEndian.PutUint32(header[8:], uint32(offset))
		binary.BigEndian.PutUint32(header[12:], imageSize)
		image := data[offset : offset+imageSize]
		binary.LittleEndian.PutUint32(image, 0xfeedfacf)
		binary.LittleEndian.PutUint32(image[4:], architecture[0])
		binary.LittleEndian.PutUint32(image[8:], architecture[1])
		binary.LittleEndian.PutUint32(image[12:], 6) // MH_DYLIB
		image[32] = marker + byte(index)
	}
	return data, bytes.Clone(data[headerSize+2*imageSize:])
}

func compactFixture() ([]fileSpec, map[string][]byte, Bundle) {
	source := map[string][]byte{"AppleMediaServices": []byte("thin AMS"), "CoreFP.icxs": []byte("ICXS data")}
	compact := map[string][]byte{"AppleMediaServices": source["AppleMediaServices"], "CoreFP.icxs": source["CoreFP.icxs"]}
	source["commerce"], compact["commerce"] = universalFixture(1)
	source["CoreFP"], compact["CoreFP"] = universalFixture(11)
	var specs []fileSpec
	for _, name := range []string{"AppleMediaServices", "commerce", "CoreFP", "CoreFP.icxs"} {
		spec := fileSpec{name: name, size: len(compact[name]), digest: sha256.Sum256(compact[name])}
		if len(source[name]) != spec.size {
			spec.universalSize = len(source[name])
			spec.universalDigest = sha256.Sum256(source[name])
		}
		specs = append(specs, spec)
	}
	return specs, source, bundleFrom(compact)
}

func writeFixture(t *testing.T, directory string, files map[string][]byte) {
	t.Helper()
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(directory, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func requireCompactCache(t *testing.T, directory string, want Bundle) {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 4 {
		t.Fatalf("cache entries = %v, error = %v", entries, err)
	}
	for name, data := range bundleFiles(want) {
		got, err := os.ReadFile(filepath.Join(directory, name))
		if err != nil || !bytes.Equal(got, data) {
			t.Fatalf("cached %s differs from the pinned compact image: %v", name, err)
		}
	}
}

func TestCacheCompactsUniversalAndResumesMixedMigrationOffline(t *testing.T) {
	for _, state := range []string{"universal", "mixed", "compact"} {
		t.Run(state, func(t *testing.T) {
			specs, files, want := compactFixture()
			if state == "mixed" {
				files["commerce"] = want.Commerce
			} else if state == "compact" {
				files = bundleFiles(want)
			}
			directory := t.TempDir()
			writeFixture(t, directory, files)
			resolve := func(context.Context) (Bundle, error) {
				t.Fatal("valid cached components must not trigger another download")
				return Bundle{}, nil
			}
			got, err := loadDirectory(context.Background(), directory, specs, resolve)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("migrated bundle differs: %v", err)
			}
			requireCompactCache(t, directory, want)
			before := make(map[string]os.FileInfo)
			for _, spec := range specs {
				before[spec.name], err = os.Stat(filepath.Join(directory, spec.name))
				if err != nil {
					t.Fatal(err)
				}
			}
			if _, err := loadDirectory(context.Background(), directory, specs, resolve); err != nil {
				t.Fatal(err)
			}
			for _, spec := range specs {
				after, err := os.Stat(filepath.Join(directory, spec.name))
				if err != nil || !os.SameFile(before[spec.name], after) {
					t.Fatalf("warm load unnecessarily replaced %s: %v", spec.name, err)
				}
			}
		})
	}
}

func TestColdExtractionAndDamagedCacheRepair(t *testing.T) {
	for _, state := range []string{"missing", "damaged compact", "damaged unused architecture"} {
		t.Run(state, func(t *testing.T) {
			specs, originals, want := compactFixture()
			extracted := t.TempDir()
			writeFixture(t, extracted, originals)
			directory := t.TempDir()
			if state == "damaged compact" {
				files := bundleFiles(want)
				files["CoreFP"] = bytes.Clone(files["CoreFP"])
				files["CoreFP"][32] ^= 1
				writeFixture(t, directory, files)
			} else if state == "damaged unused architecture" {
				originals["CoreFP"] = bytes.Clone(originals["CoreFP"])
				originals["CoreFP"][8+3*20+32] ^= 1
				writeFixture(t, directory, originals)
			}
			calls := 0
			resolve := func(ctx context.Context) (Bundle, error) {
				calls++
				return readExtractedAssets(ctx, extracted, specs)
			}
			got, err := loadDirectory(context.Background(), directory, specs, resolve)
			if err != nil || !reflect.DeepEqual(got, want) || calls != 1 {
				t.Fatalf("repair error = %v, downloads = %d, correct bundle = %v", err, calls, reflect.DeepEqual(got, want))
			}
			requireCompactCache(t, directory, want)
		})
	}
}

func TestCompactionVerifiesOriginalAndSelectedSliceBeforeReplacement(t *testing.T) {
	for _, state := range []string{"changed unused architecture", "wrong slice digest", "wrong slice size", "wrong source size", "no arm64e slice"} {
		t.Run(state, func(t *testing.T) {
			specs, originals, _ := compactFixture()
			spec := specs[1]
			data := bytes.Clone(originals[spec.name])
			switch state {
			case "changed unused architecture":
				data[8+3*20+32] ^= 1
			case "wrong slice digest":
				spec.digest[0] ^= 1
			case "wrong slice size":
				spec.size++
			case "wrong source size":
				data = data[:len(data)-1]
			case "no arm64e slice":
				binary.BigEndian.PutUint32(data[8+2*20+4:], 0x80000000)
				binary.LittleEndian.PutUint32(data[8+3*20+2*48+8:], 0x80000000)
				spec.universalDigest = sha256.Sum256(data)
			}
			directory := t.TempDir()
			path := filepath.Join(directory, spec.name)
			writeFixture(t, directory, map[string][]byte{spec.name: data})
			if _, err := readCachedAsset(context.Background(), path, spec); err == nil {
				t.Fatal("compaction accepted an unverified image")
			}
			after, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(after, data) {
				t.Fatalf("failed migration changed the source file: %v", err)
			}
		})
	}
}

func TestCancelledCompactionKeepsExistingCacheAndAvoidsDownloads(t *testing.T) {
	specs, files, want := compactFixture()
	directory := t.TempDir()
	writeFixture(t, directory, files)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := loadDirectory(ctx, directory, specs, func(context.Context) (Bundle, error) {
		t.Fatal("cancelled load started a download")
		return Bundle{}, nil
	}); !errors.Is(err, context.Canceled) {
		t.Fatalf("load error = %v, want cancellation", err)
	}
	path := filepath.Join(directory, "CoreFP")
	if _, err := readCachedAsset(ctx, path, specs[2]); !errors.Is(err, context.Canceled) {
		t.Fatalf("migration error = %v, want cancellation", err)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(after, files["CoreFP"]) {
		t.Fatalf("cancelled migration changed the original: %v", err)
	}
	if err := writeCache(ctx, directory, want, specs); !errors.Is(err, context.Canceled) {
		t.Fatalf("cache write error = %v, want cancellation", err)
	}
	after, err = os.ReadFile(path)
	if err != nil || !bytes.Equal(after, files["CoreFP"]) {
		t.Fatalf("cancelled write changed the original: %v", err)
	}
}

func TestUnwritableLegacyCacheStillLoadsWithoutDownload(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses directory write permissions")
	}
	specs, files, want := compactFixture()
	directory := t.TempDir()
	writeFixture(t, directory, files)
	if err := os.Chmod(directory, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(directory, 0o700) })
	got, err := loadDirectory(context.Background(), directory, specs, func(context.Context) (Bundle, error) {
		t.Fatal("valid read-only cache triggered a download")
		return Bundle{}, nil
	})
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("read-only cache did not load: %v", err)
	}
	for name, original := range files {
		after, err := os.ReadFile(filepath.Join(directory, name))
		if err != nil || !bytes.Equal(after, original) {
			t.Fatalf("failed compaction changed %s: %v", name, err)
		}
	}
}

func TestFailedReplacementDoesNotRemoveDestination(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "existing-directory")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := replaceFile(path, []byte("replacement")); err == nil || !strings.Contains(err.Error(), "install cache file") {
		t.Fatalf("replacement error = %v, want rename failure", err)
	}
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		t.Fatalf("failed replacement removed the destination: %v", err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 {
		t.Fatalf("failed replacement left temporary files: %v", err)
	}
}
