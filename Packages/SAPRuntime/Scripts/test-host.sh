#!/bin/bash
# Validate the same statically linked API used by iOS, including the Apple
# arm64 variadic-call shim when run on an Apple Silicon CI runner.
set -euo pipefail
runtime_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$runtime_root/../.." && pwd)"
output_root="${ASSPP_SAP_BUILD_ROOT:-$repository_root/.build/SAPRuntime}"
"$runtime_root/Scripts/build.sh" host
export CGO_ENABLED=1
export CGO_CFLAGS="-I$output_root/source/unicorn-engine-sys-tci/include"
export CGO_LDFLAGS="$output_root/host/libunicorn.a -lm -lpthread"
cd "$runtime_root"
go test -p 4 -tags asspp_static ./...
go test -p 4 -race -tags asspp_static -run 'TestOperation|TestConcurrent|TestInput|TestFailure' .
link_flags=(-lpthread -lm)
if [ "$(uname -s)" = Darwin ]; then
    link_flags+=(-framework CoreFoundation -framework Security -lresolv)
fi
cc -Wall -Wextra -Werror -I "$repository_root/Packages/ApplePackage/Sources/AppleSAP" \
    "$runtime_root/Tests/bridge-smoke.c" "$output_root/host/libAssppSAPRuntime.a" \
    "$output_root/host/libunicorn.a" "${link_flags[@]}" -o "$output_root/host/bridge-smoke"
if [ "$(uname -s)" = Darwin ]; then
    # No allow-jit or unsigned-executable-memory entitlement. This catches an
    # accidental executable-memory dependency before a device IPA is produced.
    codesign --force --sign - --options runtime "$output_root/host/bridge-smoke"
fi
if [ "${ASSPP_SAP_LIVE_PROBE:-0}" = 1 ]; then
    cache_root="${ASSPP_SAP_PROBE_CACHE:-$output_root/probe-cache}"
    "$output_root/host/bridge-smoke" "$cache_root"
else
    "$output_root/host/bridge-smoke"
fi
