[Nederlands](VALIDATION.md) · [English](VALIDATION.en.md)

# Validation of 1.0.0

These results describe the checks that were performed. They are not a complete
quality guarantee or independent certification.

| Check | Result and coverage |
| :--- | :--- |
| Build 21 self-tests | 973 records passed; 72 are observational microfade cases, not strict assertions about artistic intent. |
| Packaging | 15 guards passed, including source/bundle identity and executable permissions. |
| Official EBU v05 | 68 numerical checks and 2 time-course checks passed at 48 kHz, mono/stereo. 66 of 70 files used; surround/live-meter files outside the applicable scope. |
| Session stress | 59 lifecycle and session behaviour checks passed. |
| Native failure paths | 25 checks passed, including helper termination and a deliberately full test disk. |
| Long input | Two hours of synthetic stereo at 96 kHz: approximately 9 minutes of analysis, approximately 165 MiB peak RAM. |
| DMG | Internal checksums, app bytes, signature, Applications link and guide checked. A copied app successfully analysed generated audio and exported JSON. |
| GUI | Finder installation window, installation PDF, core keyboard shortcuts, preview reuse and HTML branding checked locally. |

## Remaining limits

- **RAM budget:** observed growth of approximately 134 MiB exceeds the internal
  128 MiB budget. This remains open; it does not by itself prove a memory leak.
- **iCloud:** real offline or interrupted downloads of larger files have not been
  fully tested. Use locally available audio for the first testing round.
- **Meters:** EBU coverage does not apply to all sample rates. Short LRA and other
  boundary cases need further cross-checks. At 192 kHz and above, the app reports
  sample peak without true-peak interpolation.
- **Interpretation:** genre references are a pilot. Clicks, silences, plateaus and
  tonal deviations remain candidates for listening checks. Artistic intent and
  individual instrument problems cannot be identified reliably.
- **Distribution:** ad-hoc signed, not notarized. First-download Gatekeeper
  behaviour on a second Mac has not yet been confirmed.
- **Reports:** HTML has been inspected. Native print/PDF pagination and CSV import
  into Logic have not been signed off separately.
- **Advice quality:** further listening assessment by Yves and testers follows
  this 1.0 build. A full VoiceOver audit is outside this first round.

No private audio or complete local test archives are included in this repository.
The measurement sources and source manifest identify the relevant implementation;
external test sets are not claimed to be included.

English GitHub documentation does not imply that the app interface or exported
reports have been translated. The distributed 1.0 app remains in Dutch.
