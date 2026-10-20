#!/usr/bin/env python3
"""Collect deterministic release assets and create the shared static manifest."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
from urllib.error import HTTPError
from urllib.request import urlopen

from release import ROOT, VERSION, android_version, validate
import re

ENDPOINT = "https://github.com/leowzz/deskbar/releases/latest/download/latest.json"


def should_promote(tag):
    try:
        with urlopen(ENDPOINT, timeout=30) as response:
            body = response.read(1024 * 1024 + 1)
            if len(body) > 1024 * 1024:
                raise ValueError("Latest manifest is too large")
            current = json.loads(body)["version"]
    except HTTPError as error:
        if error.code == 404:
            return True
        raise
    if not re.fullmatch(VERSION, current):
        raise ValueError("Latest manifest version is invalid")
    return tuple(map(int, tag[1:].split("."))) > tuple(map(int, current.split(".")))


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def names(tag):
    return {
        "macos": f"deskbar-macos-arm64-{tag}.dmg",
        "macos-update": f"deskbar-macos-arm64-{tag}.app.tar.gz",
        "windows": f"deskbar-windows-x64-{tag}.exe",
        "android": f"deskbar-android-arm64-{tag}.apk",
    }


def collect(platform, source, destination, tag):
    expected = names(tag)
    patterns = {
        "macos": [("macos", "**/*.dmg"), ("macos-update", "**/*.app.tar.gz")],
        "windows": [("windows", "**/*-setup.exe")],
        "android": [("android", "app-release.apk")],
    }
    destination.mkdir(parents=True, exist_ok=True)
    for key, pattern in patterns[platform]:
        candidates = list(source.glob(pattern))
        if len(candidates) != 1:
            raise ValueError(f"Expected one {pattern}, found {len(candidates)}")
        path = candidates[0]
        if path.stat().st_size == 0:
            raise ValueError(f"Empty artifact: {path.name}")
        target = destination / expected[key]
        shutil.copyfile(path, target)
        if key in ("macos-update", "windows"):
            signature = path.with_name(path.name + ".sig")
            if not signature.is_file() or not signature.read_text().strip():
                raise ValueError(f"Missing updater signature: {path.name}")
            shutil.copyfile(signature, target.with_name(target.name + ".sig"))
    checksums = {
        p.name: digest(p) for p in destination.iterdir()
        if p.is_file() and p.name.startswith("deskbar-") and not p.name.endswith(".json")
    }
    (destination / f"{platform}-checksums.json").write_text(json.dumps(checksums, indent=2) + "\n")


def manifest(directory, tag, code):
    expected = names(tag)
    files = set(expected.values()) | {expected[k] + ".sig" for k in ("macos-update", "windows")}
    hashes = {}
    for platform in ("macos", "windows", "android"):
        entries = json.loads((directory / f"{platform}-checksums.json").read_text())
        if hashes.keys() & entries.keys():
            raise ValueError("Duplicate release artifact")
        hashes.update(entries)
    if set(hashes) != files:
        raise ValueError("Release artifact set is incomplete or unexpected")
    for name, checksum in hashes.items():
        path = directory / name
        if not path.is_file() or not path.stat().st_size or digest(path) != checksum:
            raise ValueError(f"Artifact integrity check failed: {name}")
    base = f"https://github.com/leowzz/deskbar/releases/download/{tag}/"

    def platform(key):
        name = expected[key]
        signature = (directory / (name + ".sig")).read_text().strip()
        # Tauri stores a base64-encoded minisign envelope, not a URL.
        decoded = base64.b64decode(signature, validate=True).decode()
        if not decoded.startswith("untrusted comment:") or len(decoded.splitlines()) < 4:
            raise ValueError(f"Invalid updater signature: {name}")
        return {"url": base + name, "signature": signature}

    result = {
        "version": tag[1:],
        "notes": f"DeskBar {tag}",
        "pub_date": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "platforms": {
            "darwin-aarch64": platform("macos-update"),
            "windows-x86_64": platform("windows"),
        },
        "android": {
            "url": base + expected["android"],
            "version_code": code,
            "sha256": hashes[expected["android"]],
            "size": (directory / expected["android"]).stat().st_size,
        },
    }
    (directory / "latest.json").write_text(json.dumps(result, indent=2) + "\n")
    hashes["latest.json"] = digest(directory / "latest.json")
    (directory / "SHA256SUMS").write_text(
        "".join(f"{hashes[name]}  {name}\n" for name in sorted(hashes))
    )
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["collect", "manifest", "preflight", "promote"])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--platform", choices=["macos", "windows", "android"])
    parser.add_argument("--source", type=Path)
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    validate(args.tag)
    if args.command == "collect":
        if not args.platform or not args.source:
            parser.error("collect requires --platform and --source")
        collect(args.platform, args.source, args.directory, args.tag)
    elif args.command == "manifest":
        manifest(args.directory, args.tag, android_version()[1])
    elif args.command == "promote":
        print(str(should_promote(args.tag)).lower())
    else:
        for name in [
            "TAURI_SIGNING_PRIVATE_KEY", "DESKBAR_ANDROID_KEYSTORE_BASE64",
            "DESKBAR_ANDROID_KEYSTORE_PASSWORD", "DESKBAR_ANDROID_KEY_ALIAS",
            "DESKBAR_ANDROID_KEY_PASSWORD",
        ]:
            if not os.environ.get(name):
                raise ValueError(f"Missing repository secret: {name}")
        groups = [
            ["APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY"],
            ["APPLE_ID", "APPLE_PASSWORD", "APPLE_TEAM_ID"],
        ]
        for group in groups:
            present = [bool(os.environ.get(name)) for name in group]
            if any(present) and not all(present):
                raise ValueError(f"Provide all or none of: {', '.join(group)}")
        if os.environ.get("APPLE_ID") and not os.environ.get("APPLE_CERTIFICATE"):
            raise ValueError("Notarization requires Apple signing credentials")


if __name__ == "__main__":
    main()
