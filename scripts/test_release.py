import base64
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import release
import release_assets
import restore_android_keystore


class AndroidSigningTests(unittest.TestCase):
    def test_accepts_wrapped_base64(self):
        data = b"\xfe\xed\xfe\xed" + b"release-keystore-fixture"
        encoded = base64.b64encode(data).decode()
        wrapped = "\r\n".join(encoded[i:i + 8] for i in range(0, len(encoded), 8))
        self.assertEqual(restore_android_keystore.decode_keystore(wrapped + "\n"), data)

    def test_rejects_invalid_secret_without_echoing_it(self):
        for value in ["", "/private/release.jks", "invalid!secret", base64.b64encode(b"not a JKS").decode()]:
            with self.subTest(value=value), self.assertRaises(ValueError) as error:
                restore_android_keystore.decode_keystore(value)
            if value:
                self.assertNotIn(value, str(error.exception))

    def test_restore_writes_private_file_and_invalid_input_creates_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "release.jks"
            with patch.dict(os.environ, {"DESKBAR_ANDROID_KEYSTORE_BASE64": "invalid!secret"}):
                with self.assertRaises(ValueError):
                    restore_android_keystore.restore_keystore(path)
            self.assertFalse(path.exists())
            data = b"\xfe\xed\xfe\xed" + b"release-keystore-fixture"
            with patch.dict(os.environ, {"DESKBAR_ANDROID_KEYSTORE_BASE64": base64.b64encode(data).decode()}):
                restore_android_keystore.restore_keystore(path)
            self.assertEqual(path.read_bytes(), data)
            if os.name != "nt":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_preflight_rejects_invalid_keystore(self):
        secrets = {name: "fixture" for name in [
            "TAURI_SIGNING_PRIVATE_KEY", "DESKBAR_ANDROID_KEYSTORE_BASE64",
            "DESKBAR_ANDROID_KEYSTORE_PASSWORD", "DESKBAR_ANDROID_KEY_ALIAS",
            "DESKBAR_ANDROID_KEY_PASSWORD",
        ]}
        with patch.dict(os.environ, secrets), patch.object(sys, "argv", [
            "release_assets.py", "preflight", "--tag", release.validate(),
        ]), self.assertRaisesRegex(ValueError, "DESKBAR_ANDROID_KEYSTORE_BASE64"):
            release_assets.main()


@unittest.skipUnless(shutil.which("bash"), "Editor build requires Bash")
class EditorBuildTests(unittest.TestCase):
    def test_base_href_is_protected_from_git_bash_path_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            script = root / "scripts/build_editor.sh"
            script.write_text((release.ROOT / "scripts/build_editor.sh").read_text(), newline="\n")
            web = root / "apps/android/build/web"
            web.mkdir(parents=True)
            (web / "index.html").write_text('<base href="/editor/">')
            bin_path = root / "bin"
            bin_path.mkdir()
            flutter = bin_path / "flutter"
            flutter.write_text(
                '#!/usr/bin/env bash\nset -euo pipefail\n'
                '[[ "${MSYS_NO_PATHCONV:-}" == 1 ]]\n'
                'for argument in "$@"; do\n'
                '  if [[ "$argument" == --base-href=/editor/ ]]; then exit 0; fi\n'
                'done\nexit 1\n', newline="\n",
            )
            flutter.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_path) + os.pathsep + os.environ["PATH"])
            subprocess.run(["bash", script.as_posix()], env=env, check=True, capture_output=True)
            self.assertEqual((root / "apps/desktop/public/editor/index.html").read_text(),
                             '<base href="/editor/">')


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

    def test_release_handles_chinese_config_with_a_windows_default_encoding(self):
        original_open = Path.open

        def windows_open(path, mode="r", buffering=-1, encoding=None, errors=None, newline=None):
            if "b" not in mode and encoding in (None, "locale"):
                encoding = "cp1252"
            return original_open(path, mode, buffering, encoding, errors, newline)

        with patch.object(Path, "open", windows_open), patch.object(
            io, "text_encoding", side_effect=lambda encoding, *args: encoding or "cp1252",
        ):
            release.release(self.root / ".env")
            self.assertEqual(release.validate(), self.next)

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
