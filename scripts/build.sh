#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
python="$(command -v python3)"
stage="$(mktemp -d /private/tmp/ya-mixcheck-build.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
"$python" scripts/release_tools.py snapshot "$root" "$stage"
arch="$("$python" scripts/release_tools.py config "$root" architecture)"
minimum="$("$python" scripts/release_tools.py config "$root" minimumMacOS)"
target="${arch}-apple-macos${minimum}"
app="$stage/YA-MixCheck.app"
mkdir -p "$app/Contents/MacOS" "$stage/objects" /private/tmp/ya-mixcheck-module-cache
cd "$stage/source"
{ xcrun clang --version | sed -n '1p'; xcrun swiftc --version | sed -n '1p'; } > "$stage/toolchain.txt"
for unit in ebur128 Measure Features MP3 FLAC PreviewGain; do
    source="Sources/$unit.c"
    if [ "$unit" = ebur128 ]; then source=Vendor/ebur128.c; fi
    xcrun clang -target "$target" -O2 -Wall -Wextra -I Vendor -I Sources -c "$source" -o "$stage/objects/$unit.o"
done
xcrun swiftc -target "$target" -O -swift-version 5 -module-cache-path /private/tmp/ya-mixcheck-module-cache -import-objc-header Sources/Measure.h Sources/*.swift "$stage"/objects/*.o -o "$app/Contents/MacOS/YA-MixCheck" -framework SwiftUI -framework AppKit -framework AVFoundation -framework CryptoKit
"$python" scripts/release_tools.py finish "$stage"
test "$(lipo -archs "$app/Contents/MacOS/YA-MixCheck")" = "$arch"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$python" scripts/release_tools.py receipt "$root" "$app" "$stage/build-receipt.json"
# Only the generated build is replaced, after the complete local build passed its checks.
mkdir -p "$root/build"
rm -rf "$root/build/YA-MixCheck.app"
/usr/bin/ditto --norsrc --noextattr "$app" "$root/build/YA-MixCheck.app"
cp "$stage/build-receipt.json" "$root/build/YA-MixCheck-build.json"
printf 'Built: %s/build/YA-MixCheck.app (arm64, macOS %s; tests not run by build.sh)\n' "$root" "$minimum"
