[Nederlands](CHANGELOG.md) · [English](CHANGELOG.en.md)

# Changelog

## 1.0.0 · build 21 · 27 October 2026

First 1.0 distribution for testers, for Apple Silicon and macOS 15 or later.

- Dashboard with seven-band tonal balance, whole-track dynamics, stereo and technical checks.
- Up to three combined listening suggestions, distinguishing local from persistent deviations.
- Improved local sub-bass analysis, channel balance, clipping and dropout detection.
- Reference identification across encodings excludes a recognised track from its own reference group.
- Temporary EQ preview is reused while its input and correction remain unchanged.
- Playback, crossfade, keyboard and button hit-area improvements.
- Isolated input copies, cancellation and bounded helpers for problematic inputs.
- HTML reports in Yves Wortel branding, JSON schema 13 and CSV markers.
- Official EBU minimum validation of the applicable mono/stereo measurement engine at 48 kHz.
- DMG with an Applications shortcut and a short Dutch installation guide.
- Updated repository, build scripts and README using the same branding.

### Known limits

Not notarized; macOS may require **Open Anyway** on the first launch.
Genre references are a pilot, advice remains interpretive, and not every technical
or musical issue can be detected. Complete iCloud failure handling,
second-Mac/Gatekeeper acceptance and native report print pagination have not been
fully validated. At 192 kHz and above, sample peak only.

[Exact validation coverage and remaining limits](docs/VALIDATION.en.md).

`RELEASE-NOTES.txt` is the unchanged Dutch snapshot embedded in the app when it was
built on 27 October. Its distribution status predates the GitHub release; GitHub
Releases reflects the current publication status.

### Documentation update

English README, build guide, validation notes and this changelog are available,
with links to their Dutch versions. An English installation PDF is attached
separately to the release. The published 1.0 app, its language, DMG bytes and
checksum are unchanged.
