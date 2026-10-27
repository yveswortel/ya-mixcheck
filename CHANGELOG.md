# Changelog

## 1.0.0 · build 21 · 27 oktober 2026

Eerste 1.0-distributie voor testers, voor Apple Silicon en macOS 15 of nieuwer.

- Dashboard met zevenbandige toonbalans, hele-track dynamics, stereo en technische controles.
- Maximaal drie gecombineerde luisteradviezen, met lokale versus aanhoudende afwijkingen.
- Verbeterde lokale subanalyse, kanaalbalans, clipping- en dropoutdetectie.
- Referentieherkenning over verschillende encoderingen voorkomt zelfvergelijking.
- Tijdelijke EQ-preview wordt hergebruikt zolang de invoer en correctie gelijk blijven.
- Playback-, crossfade-, toetsbediening- en klikvlakverbeteringen.
- Geïsoleerde invoerkopieën, annulering en begrensde helpers voor probleemgevallen.
- HTML-rapporten in Yves Wortel-branding, JSON-schema 13 en CSV-markers.
- Officiële EBU-minimumvalidatie voor de toegepaste mono/stereo-meetkern op 48 kHz.
- DMG met Apps-link en korte Nederlandstalige installatiehandleiding.
- Bijgewerkte repository, bouwscripts en README in dezelfde branding.

### Bekende grenzen

Niet genotariseerd; macOS kan bij de eerste start **Open toch** vereisen.
De genrereferenties zijn een pilot, adviezen blijven interpretaties, en niet elk
technisch of muzikaal probleem wordt gevonden. Volledige iCloud-foutafhandeling,
tweede-Mac/Gatekeeper-acceptatie en native rapport-printpaginatie zijn nog niet
volledig gevalideerd. Vanaf 192 kHz alleen samplepeak.

[Exacte validatie en resterende beperkingen](docs/VALIDATION.md).

`RELEASE-NOTES.txt` is de ongewijzigde, in de app opgenomen momentopname van het
bouwen op 27 oktober. De distributiestatus in die momentopname gaat vooraf aan
de GitHub-release; de actuele publicatiestatus staat bij GitHub Releases.
