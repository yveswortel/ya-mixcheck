#!/usr/bin/env python3
"""Provenance/packaging guards using disposable fixtures, no compilation or audio files."""
import json
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path
import release_tools as release

PROJECT = Path(__file__).resolve().parents[1]


class PackagingGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ya-release-test-")
        self.root = Path(self.tmp.name) / "project"
        for name in release.inputs(PROJECT):
            dst = self.root / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, dst)
        self.stage = Path(self.tmp.name) / "stage"
        self.stage.mkdir()
        release.snapshot(self.root, self.stage)
        (self.stage / "toolchain.txt").write_text("fixture; no compilation\n")
        self.app = self.stage / "YA-MixCheck.app"
        exe = self.app / "Contents/MacOS/YA-MixCheck"
        exe.parent.mkdir(parents=True)
        exe.write_bytes(b"test fixture, not an application")
        exe.chmod(0o755)
        release.finish(self.stage)
        self.receipt = self.stage / "receipt.json"
        release.receipt(self.root, self.app, self.receipt)

    def tearDown(self):
        self.tmp.cleanup()

    def verify(self):
        return release.verify(self.root, self.app, self.receipt)

    def test_complete_matching_fixture(self):
        self.assertEqual(self.verify()["release"], release.config(PROJECT))

    def test_changed_source_is_rejected(self):
        with (self.root / "Sources/Core.swift").open("a") as f:
            f.write("\n// changed source\n")
        with self.assertRaisesRegex(ValueError, "stale"):
            self.verify()

    def test_added_source_is_rejected(self):
        (self.root / "Sources/New.swift").write_text("// newly added input")
        with self.assertRaisesRegex(ValueError, "stale"):
            self.verify()

    def test_missing_required_reference_is_rejected(self):
        (self.root / "ReferenceLibrary/DynamicsReferences.json").unlink()
        with self.assertRaisesRegex(ValueError, "Required regular file"):
            self.verify()

    def test_changed_resource_is_rejected(self):
        (self.app / "Contents/Resources/ToneReferences.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "Bundle changed"):
            self.verify()

    def test_extra_bundle_file_is_rejected(self):
        (self.app / "Contents/Resources/private-debug.txt").write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "Bundle changed"):
            self.verify()

    def test_nonexecutable_bundle_is_rejected(self):
        (self.app / "Contents/MacOS/YA-MixCheck").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "readable and executable"):
            self.verify()

    def test_owner_only_executable_is_rejected(self):
        (self.app / "Contents/MacOS/YA-MixCheck").chmod(0o700)
        with self.assertRaisesRegex(ValueError, "readable and executable"):
            self.verify()

    def test_supported_audio_is_alternate_viewer_not_default_editor(self):
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        types = info["CFBundleDocumentTypes"]
        self.assertEqual(len(types), 1)
        self.assertEqual(types[0]["CFBundleTypeRole"], "Viewer")
        self.assertEqual(types[0]["LSHandlerRank"], "Alternate")
        self.assertEqual(set(types[0]["LSItemContentTypes"]), {
            "com.microsoft.waveform-audio", "public.aiff-audio", "public.mp3", "org.xiph.flac"})

    def test_missing_receipt_is_rejected(self):
        self.receipt.unlink()
        with self.assertRaisesRegex(ValueError, "Required regular file"):
            self.verify()

    def test_source_symlink_is_rejected(self):
        source = self.root / "Sources/Core.swift"
        source.unlink()
        source.symlink_to(PROJECT / "Sources/Core.swift")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_wrong_architecture_is_rejected(self):
        cfg = json.loads((self.root / "ReleaseConfig.json").read_text())
        cfg["architecture"] = "x86_64"
        (self.root / "ReleaseConfig.json").write_text(json.dumps(cfg))
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.verify()

    def test_manifest_has_relative_inputs_and_no_false_test_claim(self):
        m = self.verify()
        self.assertTrue(all(not Path(p).is_absolute() for p in m["inputSHA256"]))
        self.assertEqual(m["validation"]["selfTests"], "not_run_by_build_or_packager")
        self.assertNotIn(str(PROJECT), json.dumps(m))

    def test_unsynchronized_version_bump_is_rejected(self):
        cfg = json.loads((self.root / "ReleaseConfig.json").read_text())
        cfg["version"] = str(int(cfg["version"].split(".")[0]) + 1) + ".0.0"
        (self.root / "ReleaseConfig.json").write_text(json.dumps(cfg))
        with self.assertRaisesRegex(ValueError, "appVersion must match"):
            self.verify()

    def test_changes_during_build_reject_receipt(self):
        (self.root / "Sources/New.swift").write_text("// edit during compile")
        with self.assertRaisesRegex(ValueError, "Source changed during build"):
            release.receipt(self.root, self.app, self.receipt)


if __name__ == "__main__":
    unittest.main(verbosity=2)
