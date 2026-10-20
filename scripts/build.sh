#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p /private/tmp/ya-mixcheck-module-cache "build/YA-MixCheck.app/Contents/MacOS" "build/YA-MixCheck.app/Contents/Resources"
clang -O2 -I Vendor -I Sources -c Vendor/ebur128.c -o build/ebur128.o
clang -O2 -Wall -Wextra -I Vendor -I Sources -c Sources/Measure.c -o build/Measure.o
clang -O2 -Wall -Wextra -I Sources -c Sources/Features.c -o build/Features.o
clang -O2 -I Vendor -I Sources -c Sources/MP3.c -o build/MP3.o
clang -O2 -I Vendor -I Sources -c Sources/FLAC.c -o build/FLAC.o
swiftc -O -swift-version 5 -module-cache-path /private/tmp/ya-mixcheck-module-cache -import-objc-header Sources/Measure.h Sources/*.swift build/Measure.o build/Features.o build/MP3.o build/FLAC.o build/ebur128.o -o "build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck" -framework SwiftUI -framework AppKit -framework AVFoundation -framework CryptoKit
cp Vendor/dr_libs/LICENSE "build/YA-MixCheck.app/Contents/Resources/dr_flac-LICENSE.txt"
cp Vendor/COPYING "build/YA-MixCheck.app/Contents/Resources/libebur128-LICENSE.txt"
cp Vendor/minimp3/LICENSE "build/YA-MixCheck.app/Contents/Resources/minimp3-LICENSE.txt"
cat > "build/YA-MixCheck.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>YA-MixCheck</string>
<key>CFBundleDisplayName</key><string>YA-MixCheck</string>
<key>CFBundleExecutable</key><string>YA-MixCheck</string>
<key>CFBundleIdentifier</key><string>audio.yves.mixcheck</string>
<key>CFBundleVersion</key><string>20</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -f ReferenceLibrary/ToneReferences.json ]; then cp ReferenceLibrary/ToneReferences.json "build/YA-MixCheck.app/Contents/Resources/"; fi
cp Assets/AppIcon.icns "build/YA-MixCheck.app/Contents/Resources/AppIcon.icns"
xattr -cr "build/YA-MixCheck.app"
codesign --force --sign - "build/YA-MixCheck.app"
printf 'Built: %s/build/YA-MixCheck.app\n' "$PWD"

if [ -f ReferenceLibrary/DynamicsReferences.json ]; then cp ReferenceLibrary/DynamicsReferences.json build/YA-MixCheck.app/Contents/Resources/; codesign --force --sign - build/YA-MixCheck.app; fi
