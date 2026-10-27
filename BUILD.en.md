[Nederlands](BUILD.md) · [English](BUILD.en.md)

# Building and packaging

Requires Apple Silicon, macOS 15+, Xcode Command Line Tools and Python 3.
The app itself does not need development tools. SwiftUI/AppKit and AVFoundation
are system frameworks; third-party C sources and licences are in `Vendor/`.

```sh
bash scripts/build.sh
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --self-test
python3 scripts/test_release_packaging.py
bash scripts/package.sh
```

`ReleaseConfig.json` and the app version in `Sources/Core.swift` must match.
The build uses a fixed input snapshot, writes a build manifest and adds an ad-hoc
signature. Packaging checks source hashes, bundle contents and executable
permissions, then verifies the extracted ZIP. These scripts do not publish anything.
`build.sh` replaces only the generated app in `build/`.

## DMG

Installer assets are included in `Assets/Installer/`.

```sh
python3 -m venv /tmp/ya-mixcheck-packaging
/tmp/ya-mixcheck-packaging/bin/pip install dmgbuild==1.6.7 ds-store==1.3.3 mac-alias==2.2.3
/tmp/ya-mixcheck-packaging/bin/python scripts/package_dmg.py
```

To regenerate the original Dutch artwork, install Pillow and ReportLab in a
separate environment and run `scripts/make_installer_assets.py`. It uses the macOS
Georgia and Arial fonts and `tiffutil`; update the version before generating assets.
The icon is reproduced with `swift scripts/make_icon.swift Assets`.

The DMG contains the app, an Applications shortcut labelled Apps and the Dutch
installation guide. The packager refuses to overwrite an existing file and checks
the mounted and copied app. Developer ID signing and notarization are not configured.

The separate English guide is generated with
`python3 scripts/make_installation_guide_en.py` (ReportLab and the same macOS fonts).
It is attached to the GitHub release; it does not change the existing 1.0 DMG.
The published app interface and reports remain in Dutch.

## Headless measurements

```sh
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --report /path/to/mix.wav 'Pop/R&B' json /new/report.json
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --report /path/to/mix.wav 'Pop/R&B' html /new/report.html
```

Reports require a new output filename. Keep private audio, research archives,
EBU audio files, caches and local build folders out of the repository.
Reference JSON contains derived measurements, not music files.

## Reproducing 1.0

The distributed 1.0.0 build 21 was built from source manifest
`888cb4976fdb5332280710154545fe686bf7a05fe56a859911716ef12739109e`.
All inputs hashed by `release_tools.py` must match this manifest, which is included
at `YA-MixCheck.app/Contents/Resources/BuildManifest.json`.
README files and distribution artwork do not alter the measurement engine.

A new compilation gets a new build timestamp and may produce different binary
bytes depending on the toolchain. Source identity does not imply a bit-identical
rebuild. Download checksums verify the published package.

`RELEASE-NOTES.txt` is the original Dutch build-time snapshot embedded in the app.
It is preserved for provenance. See the [English changelog](../CHANGELOG.en.md)
and [GitHub release](https://github.com/yveswortel/ya-mixcheck/releases/tag/v1.0.0)
for the current distribution information.
