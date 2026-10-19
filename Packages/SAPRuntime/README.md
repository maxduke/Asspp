# Source-built SAP runtime for Asspp

Asspp's iOS signer embeds the SAP implementation from
[majd/ipatool at 1b9ff28](https://github.com/majd/ipatool/tree/1b9ff28eb467cb37f803f8e4b9f0ea20f0b09f4a/internal/sap),
compiled as a Go C archive. Unicorn's
[TCI interpreter at e3f075a](https://github.com/1rhino2/unicorn-tci/tree/e3f075a62742913bb734a55a474aec65c9e5745e)
executes the pinned Apple ARM64 SAP implementation as data. It creates no JIT
code, requests no executable translation buffers, and uses no private iOS
StoreServices APIs. There is no third-party signing server or opaque WASM module.

The local changes to ipatool are a cancellable C facade, an explicit app cache
path, verified arm64e cache compaction, progress phases, a Configurator user
agent for restore-image byte ranges, a setup redirect prohibition, and static
Unicorn function references. The
`uc_ctl` trampoline handles Apple's arm64 variadic calling convention. The TCI
source preparation script disables Darwin JIT permission helpers in interpreter
mode, including callback guards. Purego's callbacks use precompiled assembly
trampolines; they do not allocate executable code.

On first use, the runtime fetches byte ranges from Apple's pinned macOS 27.0.1
restore image and extracts about 125 MB of SAP components. It validates the
original files, retains the same arm64e slices used by the loader, and checks
their pinned sizes and SHA-256 hashes before caching about 56 MB in the guest
app's Caches directory. Existing universal caches are verified and atomically
compacted in place, one file at a time, without downloading them again. A partial
migration can resume on the next attempt. This reduces retained data and warm
reads by about 55%; the first download still extracts the original files.
No Apple framework bytes are committed or bundled in the IPA. Setup sends only
the certificate exchange envelope to Apple's SAP endpoint; login bytes are
signed locally. A single interpreter slot bounds memory and serializes cold
extraction. Each call owns its hardware identity, SAP context and output buffers.

`main.go` is the C ABI used by ApplePackage. Its 15-minute context bounds cold
preparation, downloads observe cancellation, guest calls have ipatool's one-minute
CPU timeout, and the native adapter completes cancellation immediately while the
worker cleans up. Errors expose fixed phases and numeric statuses only. The
request body and underlying error strings are never logged or returned to Swift.

## Build and validation

Install Go **1.26.6**, CMake, Python 3 and Xcode. The app's first build phase runs:

```sh
Packages/SAPRuntime/Scripts/build.sh iphoneos
# or: iphonesimulator (Apple Silicon simulator)
```

The script verifies the source archive checksum in `source-pins.json`, builds
ARM64-only Unicorn with `UNICORN_INTERPRETER=ON`, and emits both static archives
in `.build/SAPRuntime/<platform>`. It caches them using a source/SDK fingerprint.
iOS linking hides runtime globals to avoid exporting Go/Unicorn symbols into a
LiveContainer host. Build the app with `Asspp.xcworkspace` as usual.

To run the offline source tests, cancellation/concurrency tests, and C ABI smoke:

```sh
Packages/SAPRuntime/Scripts/test-host.sh
```

For a credential-free, live Apple setup and two binary-payload signing probes:

```sh
ASSPP_SAP_LIVE_PROBE=1 Packages/SAPRuntime/Scripts/test-host.sh
```

The latter runs on Apple Silicon in the iOS CI job, before the device app build.
The macOS probe is ad-hoc signed with the hardened runtime and no JIT entitlement.
It tests the same statically linked interpreter and ABI that iOS uses. Linux
upstream and TCI probes passed real Apple setup and two distinct signatures;
the cached TCI probe took about 2.3 seconds. Account login was confirmed on a
physical iPhone running iOS 27.0.1 inside LiveContainer on October 18, 2026. The
tester also confirmed the cache-compaction build on October 19, 2026. This
report does not cover every OS version,
installation method, 2FA flow or account-rotation scenario.

## Licenses and corresponding source

The copied ipatool files retain their MIT license in `Licenses/ipatool-MIT.txt`.
Unicorn TCI includes GPL-2.0 code; its license is in
`Licenses/Unicorn-GPL-2.0.txt`. The iOS combined build is distributed under those
GPL-2.0 terms, while individual MIT source files retain their notices. Existing
root source-file licenses are unchanged. A notice and license copies are bundled
in the app. CI provides an `Asspp-sources` artifact beside the IPA, and tagged releases
include `Asspp-sources.tar.gz`, containing the
exact app sources, build scripts, dependency pins, and patched Unicorn TCI source.
All Go dependency versions and checksums are recorded in `go.mod` and `go.sum`.
