#!/usr/bin/env python3
"""Local release provenance. Standard library only; never publishes or runs audio tests."""
import datetime
import hashlib
import json
import plistlib
import re
import shutil
import sys
from pathlib import Path

RESOURCES = {
    "RELEASE-NOTES.txt": "ReleaseNotes.txt",
    "ReferenceLibrary/ToneReferences.json": "ToneReferences.json",
    "ReferenceLibrary/DynamicsReferences.json": "DynamicsReferences.json",
    "ReferenceLibrary/ReferenceIdentities.json": "ReferenceIdentities.json",
    "Assets/AppIcon.icns": "AppIcon.icns",
    "Vendor/COPYING": "libebur128-LICENSE.txt",
    "Vendor/minimp3/LICENSE": "minimp3-LICENSE.txt",
    "Vendor/dr_libs/LICENSE": "dr_flac-LICENSE.txt",
}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for part in iter(lambda: f.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Required regular file missing (or symlink): " + str(path))
    return path


def config(root):
    c = json.loads(regular(root / "ReleaseConfig.json").read_text())
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", c["version"]):
        raise ValueError("Release version must be three numbers")
    if not re.fullmatch(r"[0-9]+", c["build"]):
        raise ValueError("Build must be an integer string")
    if c["architecture"] != "arm64" or c["minimumMacOS"] != "15.0":
        raise ValueError("This build currently supports arm64 / macOS 15.0 only")
    if c["bundleIdentifier"] != "audio.yves.mixcheck":
        raise ValueError("Unexpected bundle identifier")
    return c


def inputs(root):
    c = config(root)
    core = regular(root / "Sources/Core.swift").read_text()
    app_versions = re.findall(r'var\s+appVersion\s*=\s*"([^"]+)"', core)
    if app_versions != [c["version"]]:
        raise ValueError("Core.swift appVersion must match ReleaseConfig.json; sync both before a version bump")
    paths = {"ReleaseConfig.json", "scripts/build.sh", "scripts/release_tools.py", *RESOURCES}
    paths.update(str(p.relative_to(root)) for p in (root / "Sources").glob("*")
                 if p.suffix in (".swift", ".c", ".h"))
    paths.update(str(p.relative_to(root)) for p in (root / "Vendor").rglob("*")
                 if p.is_file() and p.name != ".DS_Store")
    for name in ("Sources/App.swift", "Sources/Core.swift", "Sources/Measure.c", "Sources/Measure.h",
                 "Sources/Features.c", "Sources/MP3.c", "Sources/FLAC.c", "Vendor/ebur128.c"):
        paths.add(name)
    return {name: digest(regular(root / name)) for name in sorted(paths)}


def source_manifest(root):
    hashes = inputs(root)
    source_digest = hashlib.sha256(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"formatVersion": 1, "release": config(root), "sourceSHA256": source_digest, "inputSHA256": hashes}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def snapshot(root, stage):
    manifest = source_manifest(root)
    source = stage / "source"
    for name in manifest["inputSHA256"]:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    if source_manifest(source) != manifest:
        raise ValueError("Build inputs changed while making the source snapshot")
    write_json(stage / "source-manifest.json", manifest)


def finish(stage):
    manifest = json.loads((stage / "source-manifest.json").read_text())
    c = manifest["release"]
    app = stage / "YA-MixCheck.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    for source, name in RESOURCES.items():
        shutil.copyfile(regular(stage / "source" / source), resources / name)
    info = {"CFBundleName": "YA-MixCheck", "CFBundleDisplayName": "YA-MixCheck",
            "CFBundleExecutable": "YA-MixCheck", "CFBundleIdentifier": c["bundleIdentifier"],
            "CFBundleVersion": c["build"], "CFBundleShortVersionString": c["version"],
            "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": c["minimumMacOS"], "NSHighResolutionCapable": True,
            "CFBundleDocumentTypes": [{
                "CFBundleTypeName": "Supported audio",
                "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": "Alternate",
                "LSItemContentTypes": ["com.microsoft.waveform-audio", "public.aiff-audio", "public.mp3", "org.xiph.flac"],
            }]}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    manifest["builtAtUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    manifest["toolchain"] = (stage / "toolchain.txt").read_text()
    manifest["validation"] = {"selfTests": "not_run_by_build_or_packager", "signing": "ad_hoc_not_notarized"}
    write_json(resources / "BuildManifest.json", manifest)


def file_hashes(app):
    files = {}
    for p in sorted(app.rglob("*")):
        if p.is_symlink():
            raise ValueError("Unexpected bundle symlink: " + str(p))
        if p.is_file():
            files[str(p.relative_to(app))] = digest(p)
    return files


def validate_launch_permissions(app):
    # Byte hashes/code signatures do not prove that LaunchServices can execute a
    # copied bundle. ZIP readers must preserve its readable/executable mode.
    executable = regular(app / "Contents/MacOS/YA-MixCheck")
    if executable.stat().st_mode & 0o555 != 0o555:
        raise ValueError("Application executable must be readable and executable for every user")


def receipt(root, app, path):
    validate_launch_permissions(app)
    m = json.loads(regular(app / "Contents/Resources/BuildManifest.json").read_text())
    current = source_manifest(root)
    if current["sourceSHA256"] != m["sourceSHA256"] or current["inputSHA256"] != m["inputSHA256"]:
        raise ValueError("Source changed during build; rerun build.sh")
    write_json(path, {"sourceSHA256": m["sourceSHA256"], "bundleSHA256": file_hashes(app)})


def verify(root, app, receipt_path):
    validate_launch_permissions(app)
    m = json.loads(regular(app / "Contents/Resources/BuildManifest.json").read_text())
    r = json.loads(regular(receipt_path).read_text())
    current = source_manifest(root)
    if current["release"] != m["release"] or current["inputSHA256"] != m["inputSHA256"] or current["sourceSHA256"] != m["sourceSHA256"]:
        raise ValueError("Build is stale: source, resources or release config changed. Run build.sh first.")
    if r["sourceSHA256"] != m["sourceSHA256"] or r["bundleSHA256"] != file_hashes(app):
        raise ValueError("Bundle changed since the successful build; run build.sh first.")
    info = plistlib.loads(regular(app / "Contents/Info.plist").read_bytes())
    c = m["release"]
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"], info["LSMinimumSystemVersion"], info["CFBundleIdentifier"]) != (c["version"], c["build"], c["minimumMacOS"], c["bundleIdentifier"]):
        raise ValueError("Bundle identity does not match the release config")
    return m


def main():
    command, *args = sys.argv[1:]
    if command == "config":
        print(config(Path(args[0]))[args[1]])
    elif command == "snapshot":
        snapshot(Path(args[0]), Path(args[1]))
    elif command == "finish":
        finish(Path(args[0]))
    elif command == "receipt":
        receipt(*map(Path, args))
    elif command == "verify":
        m = verify(*map(Path, args))
        print("YA-MixCheck-" + m["release"]["version"] + "-arm64-" + m["sourceSHA256"][:12] + "-local.zip")
    else:
        raise ValueError("Unknown release command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit("Release check failed: " + str(error))
