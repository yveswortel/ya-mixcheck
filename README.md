# YA-MixCheck

Local macOS mix analysis and listening guidance. Version 0.5.0.

## Build

Requires macOS 15+, Apple Silicon and Xcode Command Line Tools.

```sh
bash scripts/build.sh
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --self-test
bash scripts/package.sh
```

The bundled icon is ready to use. To rebuild it from the glass master:

```sh
swift -module-cache-path /private/tmp/ya-mixcheck-module-cache scripts/make_icon.swift Assets
```

## Scope

Loudness, peaks, stereo, tonal balance and dynamics; genre-aware listening suggestions.
Diagnostic measurements do not change the original audio. Optional EQ preview writes
only a temporary audition file. Reference ranges are a small pilot collection, not
universal quality standards. No reference music is included.

0.5 adds a silver glass app icon and horizontal whole-track dynamics meters showing
P10–P90 reference ranges, median and measured value. Higher is not always better.
The 0.4.14 single-pass EQ preview remains included. Research candidate reference
curves are not activated by this release.

## Dependencies

Vendored libebur128, minimp3 and dr_flac retain their upstream license files in Vendor.
The source bundle excludes private audio, local research logs and machine paths.
The app is ad-hoc signed, not Developer ID notarized.
