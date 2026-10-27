#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
python="$(command -v python3)"
name="$("$python" scripts/release_tools.py verify "$root" build/YA-MixCheck.app build/YA-MixCheck-build.json)"
test "$(lipo -archs build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck)" = arm64
mkdir -p dist
if [ -e "dist/$name" ]; then
    printf 'Refusing to overwrite existing local candidate: dist/%s\n' "$name" >&2
    exit 1
fi
# Documents/iCloud can add FinderInfo. Sanitize and verify on local storage.
package_dir="$(mktemp -d /private/tmp/ya-mixcheck-package.XXXXXX)"
trap 'rm -rf "$package_dir"' EXIT
/usr/bin/ditto --norsrc --noextattr build/YA-MixCheck.app "$package_dir/YA-MixCheck.app"
codesign --verify --deep --strict "$package_dir/YA-MixCheck.app"
"$python" scripts/release_tools.py verify "$root" "$package_dir/YA-MixCheck.app" build/YA-MixCheck-build.json > /dev/null
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$package_dir/YA-MixCheck.app" "$package_dir/$name"
/usr/bin/ditto -x -k "$package_dir/$name" "$package_dir/check"
codesign --verify --deep --strict "$package_dir/check/YA-MixCheck.app"
"$python" scripts/release_tools.py verify "$root" "$package_dir/check/YA-MixCheck.app" build/YA-MixCheck-build.json > /dev/null
cp "$package_dir/$name" "dist/$name"
shasum -a 256 "dist/$name" > "dist/$name.sha256"
printf 'Local candidate: %s/dist/%s\nAd-hoc signed; not notarized. Tests are not run by package.sh. Nothing published.\n' "$root" "$name"
