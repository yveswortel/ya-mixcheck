# Validatie van 1.0.0

Deze resultaten beschrijven de uitgevoerde controles. Ze vormen geen volledige
kwaliteitsgarantie of onafhankelijke certificering.

| Controle | Resultaat en dekking |
| :--- | :--- |
| Zelftests op build 21 | 973 testrecords geslaagd; 72 daarvan zijn observationele microfadegevallen, geen harde intentie-asserties. |
| Packaging | 15 guards geslaagd, waaronder bron-/bundelidentiteit en uitvoerrechten. |
| Officiële EBU v05 | 68 numerieke checks en 2 tijdverloopchecks geslaagd op 48 kHz, mono/stereo. 66 van 70 bestanden gebruikt; surround/live-meterfiles buiten de toepasselijke scope. |
| Sessiestress | 59 controles geslaagd voor lifecycle en sessiegedrag. |
| Native foutpaden | 25 controles geslaagd, waaronder helperstop en een gecontroleerde volle testschijf. |
| Lange invoer | Twee uur synthetische stereo op 96 kHz: circa 9 minuten analyse, circa 165 MiB piek-RAM. |
| DMG | Interne checksums, app-bytes, handtekening, Apps-link en handleiding gecontroleerd. Een gekopieerde app kon gegenereerde audio analyseren en JSON exporteren. |
| GUI | Finder-installatievenster, installatie-PDF, kernsneltoetsen, previewhergebruik en HTML-branding lokaal gecontroleerd. |

## Openstaande grenzen

- **RAM-budget:** de gemeten groei van circa 134 MiB overschrijdt het interne
  budget van 128 MiB. Dit blijft open; het is op zichzelf geen bewezen geheugenlek.
- **iCloud:** echte offline of onderbroken downloads van grotere bestanden zijn
  niet volledig getest. Gebruik voor de eerste testronde lokaal beschikbare audio.
- **Meters:** de EBU-dekking is geen claim voor alle samplerates. Korte LRA en
  andere randgevallen hebben aanvullende kruiscontrole nodig. Vanaf 192 kHz
  rapporteert de app samplepeak, zonder true-peakinterpolatie.
- **Interpretatie:** de genrereferenties zijn een pilot. Klikken, stiltes,
  plateaus en toonafwijkingen blijven luisterkandidaten. Artistieke intentie en
  individuele instrumentproblemen worden niet betrouwbaar vastgesteld.
- **Distributie:** ad-hoc ondertekend, niet genotariseerd. Eerste-download-
  Gatekeeper-gedrag op een tweede Mac is nog niet bevestigd.
- **Rapporten:** HTML is bekeken. Native print/PDF-paginatie en CSV-import in
  Logic zijn nog niet apart afgetekend.
- **Advieskwaliteit:** verdere luisterbeoordeling door Yves en testers volgt
  op deze 1.0-build. Volledige VoiceOver-audit valt buiten deze eerste ronde.

Geen privé-audio of volledige lokale testarchieven zijn opgenomen in deze
repository. De meetkern en het bronmanifest maken de relevante implementatie
herleidbaar; ontbrekende externe testsets worden niet als meegeleverd geclaimd.
