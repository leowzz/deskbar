#!/usr/bin/env bash
set -euo pipefail
export PUB_HOSTED_URL=https://pub.dev
cd "$(dirname "$0")/../apps/android"
# Git Bash must pass this URL path through to Flutter unchanged on Windows.
MSYS_NO_PATHCONV=1 flutter build web --release --target lib/desktop_editor.dart --base-href=/editor/ --no-web-resources-cdn --no-wasm-dry-run
mkdir -p ../desktop/public/editor
python3 - <<'PY'
from pathlib import Path
import shutil
destination = Path("../desktop/public/editor")
shutil.rmtree(destination, ignore_errors=True)
shutil.copytree("build/web", destination)
PY
