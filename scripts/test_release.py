import base64
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release
import release_assets


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in release.FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(release.ROOT / name, target)
        (self.root / ".gitignore").write_text(".env\n")
        (self.root / ".env").write_text((self.root / ".env.example").read_text() + "OTHER=$(must-not-run)\n")
        self.patch = patch.object(release, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        for command in [
            ["init", "-q"], ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Release Test"], ["add", "."],
            ["commit", "-qm", "initial"],
        ]:
            release.git(*command)
        self.current = release.validate()
        a, b, c = map(int, self.current[1:].split("."))
        self.next = f"v{a}.{b}.{c + 1}"

    def test_release_synchronizes_and_creates_annotated_tag(self):
        before_code = release.android_version()[1]
        release.release(self.root / ".env")
        self.assertEqual(release.validate(), self.next)
        self.assertEqual(release.android_version()[1], before_code + 1)
        self.assertEqual(release.git("cat-file", "-t", self.next), "tag")
        self.assertEqual(release.git("status", "--porcelain"), "")
        self.assertIn("OTHER=$(must-not-run)", (self.root / ".env").read_text())

    def test_explicit_version(self):
        release.release(self.root / ".env", "v9.0.0")
        self.assertEqual(release.validate(), "v9.0.0")

    def test_rejects_dirty_tree_before_mutation(self):
        (self.root / "untracked").write_text("work in progress")
        original = (self.root / ".env").read_bytes()
        with self.assertRaises(ValueError):
            release.release(self.root / ".env")
        self.assertEqual((self.root / ".env").read_bytes(), original)

    def test_rejects_existing_tag_and_invalid_versions(self):
        release.git("tag", self.next)
        for value in [self.next, self.current, "v01.2.3", "v1.2.3-rc.1", " v1.2.3"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.release(self.root / ".env", value)
        self.assertEqual(release.validate(), self.current)

    def test_env_must_have_one_exact_assignment(self):
        for content in [
            "", "version=v1.2.3\nversion=v1.2.3\n", "version= v1.2.3\n",
            " version=v1.2.3\n", "version=v1.2.3 \n", "export version=v1.2.3\n",
        ]:
            (self.root / ".env").write_text(content)
            with self.subTest(content=content), self.assertRaises(ValueError):
                release.read_version(self.root / ".env")

    def test_mismatch(self):
        (self.root / ".env").write_text("version=v9.0.0\n")
        with self.assertRaises(ValueError):
            release.validate(env_file=self.root / ".env")

    @unittest.skipIf(os.name == "nt", "POSIX hook fixture")
    def test_commit_failure_restores_files_and_index(self):
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        original = (self.root / ".env").read_bytes()
        with self.assertRaises(subprocess.CalledProcessError):
            release.release(self.root / ".env")
        self.assertEqual((self.root / ".env").read_bytes(), original)
        self.assertEqual(release.git("status", "--porcelain"), "")
        self.assertEqual(release.git("tag", "--list"), "")


class AssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tag = "v0.1.1"
        self.names = release_assets.names(self.tag)
        signature = base64.b64encode(b"untrusted comment: fixture\nsignature\ntrusted comment: fixture\nglobal\n")
        for platform, keys in [
            ("macos", ["macos", "macos-update"]), ("windows", ["windows"]), ("android", ["android"]),
        ]:
            hashes = {}
            for key in keys:
                name = self.names[key]
                path = self.root / name
                path.write_bytes(b"artifact")
                hashes[name] = release_assets.digest(path)
                if key in ("macos-update", "windows"):
                    path = self.root / (name + ".sig")
                    path.write_bytes(signature)
                    hashes[path.name] = release_assets.digest(path)
            (self.root / f"{platform}-checksums.json").write_text(json.dumps(hashes))

    def test_static_manifest_matches_platforms_and_versioned_urls(self):
        result = release_assets.manifest(self.root, self.tag, 2)
        self.assertEqual(set(result["platforms"]), {"darwin-aarch64", "windows-x86_64"})
        self.assertEqual(result["android"]["version_code"], 2)
        self.assertIn("/releases/download/v0.1.1/", result["android"]["url"])
        self.assertNotIn("api.github.com", json.dumps(result))
        self.assertTrue((self.root / "SHA256SUMS").is_file())

    def test_rejects_missing_or_changed_artifacts(self):
        path = self.root / self.names["android"]
        path.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            release_assets.manifest(self.root, self.tag, 2)
        path.unlink()
        with self.assertRaises(ValueError):
            release_assets.manifest(self.root, self.tag, 2)

    def test_collect_requires_signature(self):
        source = self.root / "source"
        source.mkdir()
        (source / "app-setup.exe").write_bytes(b"exe")
        with self.assertRaises(ValueError):
            release_assets.collect("windows", source, self.root / "out", self.tag)

    def test_older_build_cannot_replace_latest(self):
        for current, expected in [("0.1.0", True), ("0.1.1", False), ("0.2.0", False)]:
            with patch.object(release_assets, "urlopen", return_value=io.BytesIO(
                json.dumps({"version": current}).encode()
            )):
                self.assertEqual(release_assets.should_promote(self.tag), expected)


if __name__ == "__main__":
    unittest.main()
