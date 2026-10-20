#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
# iCloud may add FinderInfo to a bundle in Documents. Package in a clean local directory.
package_dir="$(mktemp -d /private/tmp/ya-mixcheck-package.XXXXXX)"
trap 'rm -rf "$package_dir"' EXIT
/usr/bin/ditto --norsrc --noextattr build/YA-MixCheck.app "$package_dir/YA-MixCheck.app"
xattr -cr "$package_dir/YA-MixCheck.app"
codesign --force --sign - "$package_dir/YA-MixCheck.app"
codesign --verify --deep --strict "$package_dir/YA-MixCheck.app"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$package_dir/YA-MixCheck.app" dist/YA-MixCheck-0.5.0-arm64.zip
/usr/bin/ditto -x -k dist/YA-MixCheck-0.5.0-arm64.zip "$package_dir/check"
codesign --verify --deep --strict "$package_dir/check/YA-MixCheck.app"
