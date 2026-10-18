#!/bin/bash
# Run on a Mac with Xcode installed. This validates the native bridge against
# both supported SDKs without loading private frameworks or using credentials.
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
for platform in macosx iphoneos iphonesimulator; do
    case "$platform" in
        macosx) target="arm64-apple-macos15.0" ;;
        iphoneos) target="arm64-apple-ios17.0" ;;
        iphonesimulator) target="arm64-apple-ios17.0-simulator" ;;
    esac
    sdk_path="$(xcrun --sdk "$platform" --show-sdk-path)"
    xcrun --sdk "$platform" clang -fobjc-arc -fmodules -fsyntax-only \
        -Wall -Wextra -Werror -Wno-unused-parameter \
        -target "$target" -isysroot "$sdk_path" \
        -I "$package_root/Sources/AppleSAP/include" \
        "$package_root/Sources/AppleSAP/AppleSAP.m"
done
