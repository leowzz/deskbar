#!/usr/bin/env bash
# Only an explicitly selected emulator; never overwrites a physical device's pairing.
set -euo pipefail
cd "$(dirname "$0")/.."
device=${1:-}
case "$device" in
  emulator-*) ;;
  *) echo '请指定 Android 模拟器序列号，例如 ANDROID_DEVICE=emulator-5560' >&2; exit 1 ;;
esac
test_dir=$(mktemp -d)
fixture_pid=
cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
DESKBAR_FIXTURE_DIR="$test_dir" cargo test --locked -p deskbar-lan --test android_fixture -- --ignored >"$test_dir/fixture.log" 2>&1 &
fixture_pid=$!
for ((attempt=0; attempt<90; attempt++)); do
  if [ -s "$test_dir/invite.json" ]; then break; fi
  if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$test_dir/fixture.log"; exit 1; fi
  sleep 1
done
if [ ! -s "$test_dir/invite.json" ]; then echo '测试电脑启动超时' >&2; exit 1; fi
(cd apps/android && flutter test integration_test/connection_test.dart -d "$device" --dart-define-from-file="$test_dir/invite.json")
wait "$fixture_pid"
fixture_pid=
cat "$test_dir/fixture.log"
