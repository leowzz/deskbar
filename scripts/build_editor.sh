#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../apps/android"
flutter build web --release --target lib/desktop_editor.dart --base-href /editor/ --no-web-resources-cdn --no-wasm-dry-run
mkdir -p ../desktop/public/editor
rsync -a --delete build/web/ ../desktop/public/editor/
