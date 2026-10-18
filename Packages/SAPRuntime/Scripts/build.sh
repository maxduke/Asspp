#!/bin/bash
# Build only public source. Apple framework bytes are downloaded by the app,
# verified against the pinned hashes, and never redistributed in an artifact.
set -euo pipefail
runtime_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$runtime_root/../.." && pwd)"
platform="${1:-iphoneos}"
output_root="${ASSPP_SAP_BUILD_ROOT:-$repository_root/.build/SAPRuntime}"
output="$output_root/$platform"
source_root="$output_root/source"
source_archive="$output_root/unicorn-tci-source.tar.gz"
tci_commit=e3f075a62742913bb734a55a474aec65c9e5745e
tci_digest=eb8bad9a94fec1428bd5efb7a676d7c6687da03e4e6134fec149d192bfb4f6ac
for tool in go cmake python3; do
    command -v "$tool" >/dev/null || { echo "error: SAP runtime requires $tool (Go 1.26.6 and CMake)." >&2; exit 1; }
done
[ "$(go env GOVERSION)" = go1.26.6 ] || { echo 'error: SAP runtime requires Go 1.26.6.' >&2; exit 1; }
mkdir -p "$output"
cmake_options=()
compiler_options=()
case "$platform" in
    iphoneos|iphonesimulator)
        go_os=ios
        go_arch=arm64
        sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
        compiler="$(xcrun --sdk "$platform" --find clang)"
        target=arm64-apple-ios17.0
        [ "$platform" != iphonesimulator ] || target=arm64-apple-ios17.0-simulator
        compiler_options=(-target "$target" -isysroot "$sdk")
        export ARCHFLAGS='-arch arm64'
        cmake_options=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY)
        sdk_version="$(xcrun --sdk "$platform" --show-sdk-version)"
        ;;
    host)
        case "$(uname -s)" in Darwin) go_os=darwin ;; Linux) go_os=linux ;; *) exit 1 ;; esac
        case "$(uname -m)" in arm64|aarch64) go_arch=arm64 ;; x86_64) go_arch=amd64 ;; *) exit 1 ;; esac
        compiler="$(command -v cc)"
        sdk_version="$go_os-$go_arch"
        if [ "$go_os" = darwin ]; then
            sdk="$(xcrun --sdk macosx --show-sdk-path)"
            compiler_options=(-isysroot "$sdk" -mmacosx-version-min=15.0)
            export ARCHFLAGS="-arch $(uname -m)"
            cmake_options=(-DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0)
        fi
        ;;
    *) echo "error: Unsupported SAP platform: $platform" >&2; exit 1 ;;
esac
fingerprint="$(python3 - "$runtime_root" "$platform" "$sdk_version" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256("|".join(sys.argv[2:]).encode())
for path in sorted(root.rglob('*')):
    if path.is_file() and (path.suffix in {'.go', '.mod', '.sum', '.sh', '.py', '.json', '.c', '.h'}):
        h.update(str(path.relative_to(root)).encode()); h.update(path.read_bytes())
print(h.hexdigest())
PY
)"
if [ -f "$output/fingerprint" ] && [ "$(cat "$output/fingerprint")" = "$fingerprint" ] && [ -s "$output/libAssppSAPRuntime.a" ] && [ -s "$output/libunicorn.a" ]; then
    echo "SAP interpreter is current ($platform)."
    exit 0
fi
prepared_fingerprint="$(python3 - "$runtime_root/Scripts/prepare-source.py" "$tci_digest" <<'PYHASH'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read() + sys.argv[2].encode()).hexdigest())
PYHASH
)"
if [ ! -f "$source_root/.asspp-source-ready" ] || [ "$(cat "$source_root/.asspp-source-ready")" != "$prepared_fingerprint" ]; then
    echo 'Fetching pinned Unicorn TCI source...'
    mkdir -p "$source_root"
    curl --fail --location --retry 3 --silent --show-error \
        "https://codeload.github.com/1rhino2/unicorn-tci/tar.gz/$tci_commit" -o "$source_archive"
    python3 - "$source_archive" "$tci_digest" <<'PY'
import hashlib, sys
if hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() != sys.argv[2]:
    raise SystemExit('TCI source checksum mismatch')
PY
    tar -xzf "$source_archive" --strip-components=1 -C "$source_root"
    python3 "$runtime_root/Scripts/prepare-source.py" "$source_root/unicorn-engine-sys-tci"
    printf '%s\n' "$prepared_fingerprint" > "$source_root/.asspp-source-ready"
fi
# The same wrapper supplies the deployment target to CMake's configure probes
# and to cgo, which otherwise uses host-macOS compiler defaults.
compiler_wrapper="$output/cc.sh"
{
    echo '#!/bin/bash'
    printf 'exec '
    printf '%q ' "$compiler" "${compiler_options[@]}"
    printf '"$@"\n'
} > "$compiler_wrapper"
chmod +x "$compiler_wrapper"
export CC="$compiler_wrapper"
echo "Building ARM64 TCI interpreter ($platform)..."
if ! cmake -S "$source_root/unicorn-engine-sys-tci" -B "$output/unicorn" \
    -DCMAKE_C_COMPILER="$CC" -DUNICORN_ARCH=aarch64 -DUNICORN_INTERPRETER=ON \
    -DBUILD_SHARED_LIBS=OFF -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF \
    -DCMAKE_BUILD_TYPE=Release "${cmake_options[@]}" > "$output/unicorn-build.log" 2>&1; then
    tail -80 "$output/unicorn-build.log"; exit 1
fi
if ! cmake --build "$output/unicorn" --parallel "${ASSPP_SAP_BUILD_JOBS:-4}" >> "$output/unicorn-build.log" 2>&1; then
    tail -80 "$output/unicorn-build.log"; exit 1
fi
cp "$output/unicorn/libunicorn.a" "$output/libunicorn.a"
export GOOS="$go_os" GOARCH="$go_arch" CGO_ENABLED=1
export CGO_CFLAGS="-I$source_root/unicorn-engine-sys-tci/include"
export CGO_LDFLAGS="$output/libunicorn.a -lm -lpthread"
echo "Building ipatool SAP C archive ($platform)..."
cd "$runtime_root"
if ! go build -buildvcs=false -p 4 -tags asspp_static -trimpath -buildmode=c-archive -o "$output/libAssppSAPRuntime.a" . > "$output/go-build.log" 2>&1; then
    tail -80 "$output/go-build.log"; exit 1
fi
printf '%s\n' "$fingerprint" > "$output/fingerprint"
echo "SAP interpreter ready ($platform)."
