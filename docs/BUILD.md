# Bouwen en verpakken

Apple Silicon, macOS 15+, Xcode Command Line Tools en Python 3 zijn vereist.
De app zelf heeft geen ontwikkeltools nodig. SwiftUI/AppKit en AVFoundation zijn
systeemframeworks; C-bronnen en licenties staan in `Vendor/`.

```sh
bash scripts/build.sh
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --self-test
python3 scripts/test_release_packaging.py
bash scripts/package.sh
```

`ReleaseConfig.json` en de appversie in `Sources/Core.swift` moeten overeenkomen.
De build gebruikt een vaste invoersnapshot, schrijft een buildmanifest en maakt
een ad-hoc handtekening. Packaging controleert bronhashes, bundelinhoud en
uitvoerrechten, en verifieert de uitgepakte ZIP. De scripts publiceren niets.
`build.sh` vervangt uitsluitend de gegenereerde app in `build/`.

## DMG

De installer-assets staan al in `Assets/Installer/`.

```sh
python3 -m venv /tmp/ya-mixcheck-packaging
/tmp/ya-mixcheck-packaging/bin/pip install dmgbuild==1.6.7 ds-store==1.3.3 mac-alias==2.2.3
/tmp/ya-mixcheck-packaging/bin/python scripts/package_dmg.py
```

Voor nieuwe artwork: installeer Pillow en ReportLab in een aparte omgeving en
voer `scripts/make_installer_assets.py` uit. Dit gebruikt de macOS-fonts Georgia
en Arial en `tiffutil`; wijzig de versie vóór het genereren. Het app-icoon wordt
gereproduceerd met `swift scripts/make_icon.swift Assets`.

De DMG bevat alleen de app, een Apps-link en de installatiehandleiding. De
packager weigert een bestaand bestand te overschrijven en controleert de
gemounte en gekopieerde app. Developer ID en notarization zijn niet ingesteld.

## Headless metingen

```sh
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --report /path/to/mix.wav 'Pop/R&B' json /new/report.json
build/YA-MixCheck.app/Contents/MacOS/YA-MixCheck --report /path/to/mix.wav 'Pop/R&B' html /new/report.html
```

Rapporten vereisen een nieuwe bestandsnaam. Privé-audio, onderzoeksarchieven,
EBU-audiobestanden, caches en lokale buildmappen horen niet in de repository.
De referentie-JSON bevat afgeleide meetgegevens, geen muziekbestanden.

## Reproduceerbaarheid van 1.0

De meegeleverde 1.0.0 build 21 is gebouwd uit bronmanifest
`888cb4976fdb5332280710154545fe686bf7a05fe56a859911716ef12739109e`.
Alle door `release_tools.py` gehashte invoer moet hiermee overeenkomen. Het
manifest zit in `YA-MixCheck.app/Contents/Resources/BuildManifest.json`.
README en distributie-artwork veranderen de meetkern niet.

Een nieuwe compilatie krijgt een nieuwe bouwtijd en kan afhankelijk van de
toolchain andere binaire bytes opleveren. Bronidentiteit is geen claim van een
bit-identieke herbouw. De downloadchecksums verifiëren het gepubliceerde pakket.
