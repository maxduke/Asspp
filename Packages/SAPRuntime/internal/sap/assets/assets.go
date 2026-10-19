package assets

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/majd/ipatool/v2/internal/sap/machimage"
)

const (
	macOSVersion    = "27.0.1"
	macOSBuild      = "26A434"
	macOSRestoreURL = "https://updates.cdn-apple.com/2026FallFCS/59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw"
	// Keep the existing directory so verified universal files can be compacted
	// in place, without downloading them again or retaining a second cache.
	assetCacheDirectory = "apple-assets-macos-27-26A434-arm64-v1"
)

type Bundle struct {
	AppleMediaServices []byte
	Commerce           []byte
	CoreFP             []byte
	CoreFPICXS         []byte
}

type fileSpec struct {
	name   string
	size   int
	digest [32]byte
	// Universal originals are verified before selecting the same arm64e slice
	// that the Mach-O loader uses. Zero means the source is already compact.
	universalSize   int
	universalDigest [32]byte
}

var requiredFiles = []fileSpec{
	{
		name:   "AppleMediaServices",
		size:   14813888,
		digest: mustDigest("95f4558aa2c0ccd9f96ed479e336b630b46bf4b4e0baabc1c1ac8c7d55e21ab4"),
	},
	{
		name:            "commerce",
		size:            2735088,
		digest:          mustDigest("c4b2088dd39aeb353f59cb57597902e8317aec66ae7da0414b03c5f932771343"),
		universalSize:   8092640,
		universalDigest: mustDigest("76de40a4a32f691947cb926ce3b128d2fc446f7cac9755f831c406cf5a316ac9"),
	},
	{
		name:            "CoreFP",
		size:            30764976,
		digest:          mustDigest("afbc123e688a822d980d5816cc2b52f69fde669d1dca92cf85627e1cbee587f6"),
		universalSize:   94842464,
		universalDigest: mustDigest("2c30fa2b5f695fd66c0360dce72f54757d03ddb7107549715c12cb359a003b46"),
	},
	{
		name:   "CoreFP.icxs",
		size:   7365344,
		digest: mustDigest("cb8f55330ec567da3e692dab5f5388bed0312dd9093340477c5759078cc2aa7b"),
	},
}

// Load resolves and caches the pinned macOS framework profile used by SAP,
// kbsync generation, and package decryption.
func Load(ctx context.Context) (Bundle, error) {
	directory, err := cacheDirectory()
	if err != nil {
		return Bundle{}, err
	}
	return LoadDirectory(ctx, directory)
}

// LoadDirectory uses the caller's actual app container without changing HOME.
func LoadDirectory(ctx context.Context, directory string) (Bundle, error) {
	return loadDirectory(ctx, directory, requiredFiles, resolveRemoteImage)
}

func loadDirectory(ctx context.Context, directory string, specs []fileSpec, resolve func(context.Context) (Bundle, error)) (Bundle, error) {
	if ctx == nil {
		return Bundle{}, errors.New("apple asset context is nil")
	}

	if err := ctx.Err(); err != nil {
		return Bundle{}, fmt.Errorf("load Apple assets: %w", err)
	}

	if !filepath.IsAbs(directory) {
		return Bundle{}, errors.New("SAP cache directory must be absolute")
	}

	if bundle, err := readCache(ctx, directory, specs); err == nil {
		return bundle, nil
	}

	if err := ctx.Err(); err != nil {
		return Bundle{}, fmt.Errorf("load Apple assets: %w", err)
	}

	bundle, err := resolve(ctx)
	if err != nil {
		return Bundle{}, err
	}

	if err := writeCache(ctx, directory, bundle, specs); err != nil {
		return Bundle{}, fmt.Errorf("cache Apple SAP assets: %w", err)
	}

	return bundle, nil
}

func cacheDirectory() (string, error) {
	root, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("find user cache directory: %w", err)
	}

	return filepath.Join(root, "ipatool", "sap", assetCacheDirectory), nil
}

func readCache(ctx context.Context, directory string, specs []fileSpec) (Bundle, error) {
	files := make(map[string][]byte, len(specs))

	for _, spec := range specs {
		if err := ctx.Err(); err != nil {
			return Bundle{}, err
		}
		data, err := readCachedAsset(ctx, filepath.Join(directory, spec.name), spec)
		if err != nil {
			return Bundle{}, fmt.Errorf("read cached Apple SAP asset %s: %w", spec.name, err)
		}

		files[spec.name] = data
	}

	return bundleFrom(files), ctx.Err()
}

func readCachedAsset(ctx context.Context, path string, spec fileSpec) ([]byte, error) {
	data, err := readCacheFile(path, spec.size)
	if err == nil {
		return data, validateFile(data, spec)
	}
	if spec.universalSize == 0 {
		return nil, err
	}

	data, err = readCacheFile(path, spec.universalSize)
	if err != nil {
		return nil, err
	}
	data, err = compactSource(data, spec)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Each replacement is atomic. A cancelled migration may leave a mix of
	// universal and compact files, both of which are accepted on the next load.
	// Compaction is best effort: a verified existing cache must remain usable
	// when there is not enough space to persist a compact copy. Do not turn a
	// local cache-write failure into another download.
	_ = replaceFile(path, data)
	return data, nil
}

func (spec fileSpec) source() fileSpec {
	if spec.universalSize == 0 {
		return spec
	}
	return fileSpec{name: spec.name, size: spec.universalSize, digest: spec.universalDigest}
}

func compactSource(data []byte, spec fileSpec) ([]byte, error) {
	if err := validateFile(data, spec.source()); err != nil {
		return nil, err
	}
	if spec.universalSize != 0 {
		var err error
		data, err = machimage.ARM64ESlice(data)
		if err != nil {
			return nil, fmt.Errorf("select %s arm64e slice: %w", spec.name, err)
		}
		if err := validateFile(data, spec); err != nil {
			return nil, err
		}
	}
	return data, nil
}

func readCacheFile(path string, expectedSize int) ([]byte, error) {
	if expectedSize < 0 {
		return nil, errors.New("invalid expected size")
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open cached asset: %w", err)
	}

	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect cached asset: %w", err)
	}

	if info.Size() != int64(expectedSize) {
		return nil, fmt.Errorf("has size %d, expected %d", info.Size(), expectedSize)
	}

	data := make([]byte, expectedSize)
	if _, err := io.ReadFull(file, data); err != nil {
		return nil, fmt.Errorf("read cached asset: %w", err)
	}

	var extra [1]byte
	if count, err := io.ReadFull(file, extra[:]); err == nil || count != 0 {
		return nil, fmt.Errorf("grew beyond expected size %d while being read", expectedSize)
	} else if !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("verify cached asset length: %w", err)
	}

	return data, nil
}

func writeCache(ctx context.Context, directory string, bundle Bundle, specs []fileSpec) error {
	if err := validateFiles(bundle, specs); err != nil {
		return err
	}

	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create SAP asset cache: %w", err)
	}

	files := bundleFiles(bundle)
	for _, spec := range specs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := replaceFile(filepath.Join(directory, spec.name), files[spec.name]); err != nil {
			return fmt.Errorf("write cached SAP asset %s: %w", spec.name, err)
		}
	}

	return ctx.Err()
}

func replaceFile(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".download-*")
	if err != nil {
		return fmt.Errorf("create temporary cache file: %w", err)
	}

	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()

		return fmt.Errorf("set cache file permissions: %w", err)
	}

	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()

		return fmt.Errorf("write temporary cache file: %w", err)
	}

	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary cache file: %w", err)
	}

	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("install cache file: %w", err)
	}

	return nil
}

func validate(bundle Bundle) error {
	return validateFiles(bundle, requiredFiles)
}

func validateFiles(bundle Bundle, specs []fileSpec) error {
	files := bundleFiles(bundle)
	for _, spec := range specs {
		if err := validateFile(files[spec.name], spec); err != nil {
			return err
		}
	}

	return nil
}

func validateFile(data []byte, spec fileSpec) error {
	if len(data) != spec.size {
		return fmt.Errorf("apple SAP asset %s has size %d, expected %d", spec.name, len(data), spec.size)
	}
	if sha256.Sum256(data) != spec.digest {
		return fmt.Errorf("apple SAP asset %s failed integrity verification", spec.name)
	}
	return nil
}

func bundleFrom(files map[string][]byte) Bundle {
	return Bundle{
		AppleMediaServices: files["AppleMediaServices"],
		Commerce:           files["commerce"],
		CoreFP:             files["CoreFP"],
		CoreFPICXS:         files["CoreFP.icxs"],
	}
}

func bundleFiles(bundle Bundle) map[string][]byte {
	return map[string][]byte{
		"AppleMediaServices": bundle.AppleMediaServices,
		"commerce":           bundle.Commerce,
		"CoreFP":             bundle.CoreFP,
		"CoreFP.icxs":        bundle.CoreFPICXS,
	}
}

func mustDigest(value string) [32]byte {
	var digest [32]byte

	decoded, err := hex.DecodeString(value)
	if err != nil {
		panic(err)
	}

	if len(decoded) != len(digest) {
		panic("invalid SHA-256 length")
	}

	copy(digest[:], decoded)

	return digest
}
