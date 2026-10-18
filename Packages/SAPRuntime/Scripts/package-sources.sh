#!/bin/bash
# Package the exact app revision and the interpreter source used by this build.
# Call before another build script cleans .build; keep the output outside the
# checkout when a second platform build will follow.
set -euo pipefail
runtime_root="$(cd "$(dirname "$0")/.." && pwd)"
repository_root="$(cd "$runtime_root/../.." && pwd)"
output="${1:?usage: package-sources.sh /absolute/path/Asspp-sources.tar.gz}"
case "$output" in /*) ;; *) echo 'Source archive output must be absolute.' >&2; exit 1 ;; esac
build_root="${ASSPP_SAP_BUILD_ROOT:-$repository_root/.build/SAPRuntime}"
tci_source="$build_root/source/unicorn-engine-sys-tci"
[ -f "$tci_source/uc.c" ] || { echo 'Built TCI source is missing.' >&2; exit 1; }
workspace="$(mktemp -d "${TMPDIR:-/tmp}/asspp-sources.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/asspp-sources"
git -C "$repository_root" archive HEAD | tar -x -C "$workspace/asspp-sources"
git -C "$repository_root" rev-parse HEAD > "$workspace/asspp-sources/SOURCE_COMMIT"
cp -R "$tci_source" "$workspace/asspp-sources/Packages/SAPRuntime/UnicornTCISource"
tar -czf "$output" -C "$workspace" asspp-sources
echo "Corresponding source ready: $output"
