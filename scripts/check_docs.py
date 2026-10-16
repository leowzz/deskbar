#!/usr/bin/env python3
"""Check local Markdown file links, including files before the first commit."""

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]


def main():
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    paths = sorted(set(filter(None, result.stdout.split("\0"))))
    errors = []
    for name in paths:
        source = ROOT / name
        if not source.is_file():
            errors.append(f"{name}: indexed file is missing")
            continue
        content = source.read_text(encoding="utf-8")
        if "/Users/" in content or "file:///" in content:
            errors.append(f"{name}: use repository-relative links instead of workstation paths")
        prose = re.sub(r"^```[^\n]*\n.*?^```[ \t]*$", "", content, flags=re.M | re.S)
        for match in re.finditer(r"\[[^\]\n]*\]\(([^)\n]+)\)", prose):
            target = match.group(1).strip()
            if target.startswith("<"):
                target = target[1:].split(">", 1)[0]
            else:
                target = target.split(' "', 1)[0]
            link = urlsplit(target)
            if link.scheme or link.netloc or not link.path:
                continue
            destination = (source.parent / unquote(link.path)).resolve()
            try:
                destination.relative_to(ROOT)
            except ValueError:
                errors.append(f"{name}: link leaves the repository: {target}")
                continue
            if not destination.exists():
                errors.append(f"{name}: missing link target: {target}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Checked {len(paths)} Markdown files: local file links and portability OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
