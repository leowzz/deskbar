#!/usr/bin/env python3
"""Version validation and local release transaction; never source .env or push."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
FILES = [
    ".env.example",
    "Cargo.toml",
    "Cargo.lock",
    "apps/desktop/package.json",
    "apps/desktop/src-tauri/tauri.conf.json",
    "apps/android/pubspec.yaml",
]
CRATES = {"deskbar-host", "deskbar-lan", "deskbar-desktop"}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def read_version(path):
    lines = [
        line for line in path.read_text(encoding="utf-8").splitlines()
        if re.match(r"\s*(?:export\s+)?version\s*=", line)
    ]
    if len(lines) != 1 or not re.fullmatch("version=v" + VERSION, lines[0]):
        raise ValueError(f"{path.name}: expected exactly one version=vX.Y.Z")
    return lines[0].split("=", 1)[1]


def android_version():
    matches = re.findall(r"^version: (\S+)$", (ROOT / FILES[-1]).read_text(encoding="utf-8"), re.M)
    if len(matches) != 1 or not re.fullmatch(VERSION + r"\+[1-9][0-9]*", matches[0]):
        raise ValueError("pubspec.yaml: expected X.Y.Z+positiveBuildNumber")
    version, code = matches[0].split("+")
    if int(code) > 2100000000:
        raise ValueError("Android versionCode exceeds platform limit")
    return version, int(code)


def validate(tag=None, env_file=None):
    current = read_version(env_file or ROOT / ".env.example")
    if tag is not None and (not re.fullmatch("v" + VERSION, tag) or tag != current):
        raise ValueError("Tag must be a stable vX.Y.Z matching the project version")
    expected = current[1:]
    versions = {
        ".env.example": read_version(ROOT / ".env.example")[1:],
        "Cargo.toml": tomllib.loads((ROOT / "Cargo.toml").read_text(encoding="utf-8"))["workspace"]["package"]["version"],
        "pubspec.yaml": android_version()[0],
    }
    for path in FILES[3:5]:
        versions[path] = json.loads((ROOT / path).read_text(encoding="utf-8"))["version"]
    packages = tomllib.loads((ROOT / "Cargo.lock").read_text(encoding="utf-8"))["package"]
    own = [p for p in packages if p["name"] in CRATES and "source" not in p]
    if {p["name"] for p in own} != CRATES:
        raise ValueError("Cargo.lock must contain all workspace packages")
    versions.update({p["name"]: p["version"] for p in own})
    if any(v != expected for v in versions.values()):
        raise ValueError(f"Version mismatch: expected {expected}, found {versions}")
    return current


def replace_one(text, pattern, value):
    result, count = re.subn(pattern, lambda _: value, text, flags=re.M)
    if count != 1:
        raise ValueError(f"Expected one version field, found {count}")
    return result


def release(env_file, requested=None):
    current = validate(env_file=env_file)
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Worktree must be clean before make release")
    parts = tuple(map(int, current[1:].split(".")))
    target = requested or f"v{parts[0]}.{parts[1]}.{parts[2] + 1}"
    if not re.fullmatch("v" + VERSION, target):
        raise ValueError("Expected V=vX.Y.Z")
    if tuple(map(int, target[1:].split("."))) <= parts:
        raise ValueError("Release version must be newer")
    if git("tag", "--list", target):
        raise ValueError(f"Tag already exists: {target}")
    version = target[1:]
    _, code = android_version()
    if code >= 2100000000:
        raise ValueError("Android versionCode exhausted")
    paths = list(dict.fromkeys([ROOT / p for p in FILES] + [env_file]))
    originals = {p: p.read_bytes() for p in paths}
    updates = {p: data.decode() for p, data in originals.items()}
    for p in [ROOT / ".env.example", env_file]:
        updates[p] = replace_one(updates[p], r"^version=.*$", f"version={target}")
    p = ROOT / "Cargo.toml"
    updates[p] = replace_one(updates[p], r'^version = ".*"$', f'version = "{version}"')
    p = ROOT / "Cargo.lock"
    for name in CRATES:
        updates[p] = replace_one(
            updates[p], rf'^name = "{name}"\nversion = ".*"$',
            f'name = "{name}"\nversion = "{version}"',
        )
    for name in FILES[3:5]:
        p = ROOT / name
        data = json.loads(updates[p])
        data["version"] = version
        updates[p] = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    p = ROOT / FILES[-1]
    updates[p] = replace_one(updates[p], r"^version: .*", f"version: {version}+{code + 1}")
    committed = False
    try:
        for path, text in updates.items():
            path.write_text(text, encoding="utf-8")
        validate(target, env_file)
        git("add", "--", *FILES)
        git("commit", "-m", f"chore: release {target}", "--", *FILES)
        committed = True
        git("tag", "-a", target, "-m", f"release {target}")
    except BaseException:
        if not committed:
            for path, data in originals.items():
                path.write_bytes(data)
            git("reset", "--quiet", "HEAD", "--", *FILES)
        else:
            print(f"Release commit exists, but tag failed. Retry: git tag -a {target} -m 'release {target}'", file=sys.stderr)
        raise
    print(f"Created release commit and annotated tag {target}; nothing pushed.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["check", "release"])
    parser.add_argument("--tag")
    parser.add_argument("--require-branch", action="store_true")
    args = parser.parse_args()
    if args.command == "release":
        release((ROOT / os.environ.get("ENV_FILE", ".env")).resolve(), os.environ.get("V") or None)
    else:
        env_file = ROOT / os.environ.get("ENV_FILE", ".env")
        version = validate(args.tag, env_file if env_file.exists() else None)
        if args.require_branch:
            if not args.tag or git("rev-parse", f"{args.tag}^{{commit}}") != git("rev-parse", "HEAD"):
                raise ValueError("Tag does not point at checkout")
            if not git("branch", "-r", "--contains", "HEAD"):
                raise ValueError("Tag must belong to a remote branch; push the branch first")
        print(version)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"release: {error}")
