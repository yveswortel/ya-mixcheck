#!/usr/bin/env python3
"""Package the verified local build; never installs, publishes or alters the app."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import dmgbuild
import release_tools

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/YA-MixCheck.app"
RECEIPT = ROOT / "build/YA-MixCheck-build.json"
ASSETS = ROOT / "Assets/Installer"
DIST = ROOT / "dist"


def run(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def main():
    m = release_tools.verify(ROOT, APP, RECEIPT)
    version = m["release"]["version"]
    name = f"YA-MixCheck-{version}-arm64.dmg"
    output = DIST / name
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite {output}")
    for name in ("background.tiff", "Installatie.pdf"):
        release_tools.regular(ASSETS / name)

    with tempfile.TemporaryDirectory(prefix="ya-mixcheck-dmg-", dir="/private/tmp") as td:
        stage = Path(td)
        app = stage / APP.name
        # Avoid unrelated iCloud/Finder metadata on the source checkout. File bytes,
        # executable permissions and the existing signature must still match.
        run("/usr/bin/ditto", "--norsrc", "--noextattr", str(APP), str(app))
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        release_tools.verify(ROOT, app, RECEIPT)
        image = stage / output.name
        settings = {
            "format": "UDZO", "filesystem": "HFS+", "size": "32m",
            "files": [str(app), str(ASSETS / "Installatie.pdf")],
            "symlinks": {"Apps": "/Applications"},
            "icon": str(app / "Contents/Resources/AppIcon.icns"),
            "background": str(ASSETS / "background.tiff"),
            # Finder includes title/path bars in this height on current macOS.
            "window_rect": ((180, 120), (700, 550)),
            "icon_locations": {APP.name: (190, 244), "Apps": (510, 244), "Installatie.pdf": (106, 399)},
            "icon_size": 88, "text_size": 13, "label_pos": "bottom",
            "default_view": "icon-view", "arrange_by": None,
            "show_status_bar": False, "show_toolbar": False, "show_sidebar": False,
            "show_tab_view": False, "show_pathbar": False, "show_icon_preview": False,
            "include_icon_view_settings": True, "include_list_view_settings": False,
            "hide_extensions": ["Installatie.pdf"],
        }
        dmgbuild.build_dmg(str(image), f"YA-MixCheck {version}", settings=settings)
        verify_log = run("/usr/bin/hdiutil", "verify", str(image))
        mount = stage / "verify"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(image))
        try:
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(mount / APP.name))
            release_tools.verify(ROOT, mount / APP.name, RECEIPT)
            assert (mount / "Apps").is_symlink() and os.readlink(mount / "Apps") == "/Applications"
            assert release_tools.digest(mount / "Installatie.pdf") == release_tools.digest(ASSETS / "Installatie.pdf")
            # Check a copied bundle too, without touching any installed app.
            copied = stage / "copy-test" / APP.name
            run("/usr/bin/ditto", str(mount / APP.name), str(copied))
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied))
            release_tools.verify(ROOT, copied, RECEIPT)
        finally:
            run("/usr/bin/hdiutil", "detach", str(mount))

        DIST.mkdir(exist_ok=True)
        shutil.copyfile(image, output)
        sha = release_tools.digest(output)
        output.with_suffix(".dmg.sha256").write_text(f"{sha}  {output.name}\n")
        output.with_suffix(".dmg.json").write_text(json.dumps({
            "version": version, "build": m["release"]["build"],
            "sourceSHA256": m["sourceSHA256"], "dmgSHA256": sha, "bytes": output.stat().st_size,
            "signing": "app_ad_hoc_not_notarized", "publication": "not_published",
            "checks": ["source_and_bundle_receipt", "clean_copy_signature", "dmg_checksum",
                       "mounted_bundle_bytes_and_signature", "copied_bundle_bytes_and_signature",
                       "applications_link", "guide_bytes"],
            "notTested": ["first_download_Gatekeeper_on_second_Mac"],
            "packagingInputsSHA256": {str(p.relative_to(ROOT)): release_tools.digest(p) for p in
                [ASSETS / "background.tiff", ASSETS / "Installatie.pdf", Path(__file__), ROOT / "scripts/make_installer_assets.py"]},
            "hdiutilVerification": verify_log,
        }, indent=2) + "\n")
        print(output)


if __name__ == "__main__":
    main()
