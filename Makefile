.DEFAULT_GOAL := help

PYTHON ?= python3
DOCS_PORT ?= 8765
ANDROID_DEVICE ?=

.PHONY: help setup dev prototype android android-build desktop-build check docs-check test-android-connection

help:
	@printf '%s\n' 'DeskBar — 电脑旁的工作台' '  make setup          安装依赖' '  make dev            运行 DeskBar 连接助手' '  make android        运行 DeskBar 工作台（设置 ANDROID_DEVICE）' '  make check          文档与代码检查' '  make desktop-build  构建桌面开发版本' '  make android-build  构建 Android 开发 APK' '  make prototype      预览 HTML 布局原型'

setup:
	pnpm install --frozen-lockfile
	cd apps/android && flutter pub get

dev:
	pnpm --dir apps/desktop run tauri dev

prototype:
	@printf '%s\n' 'http://127.0.0.1:$(DOCS_PORT)/prototypes/workbench.html'
	$(PYTHON) -m http.server $(DOCS_PORT) --bind 127.0.0.1 --directory docs

android:
	@test -n "$(ANDROID_DEVICE)" || (echo '请指定 ANDROID_DEVICE=<设备序列号>'; exit 1)
	cd apps/android && flutter run -d "$(ANDROID_DEVICE)"

desktop-build:
	pnpm --dir apps/desktop run tauri build --debug --no-bundle

android-build:
	cd apps/android && flutter build apk --debug

docs-check:
	$(PYTHON) scripts/check_docs.py

check: docs-check
	cargo fmt --all -- --check
	cargo test --locked --workspace
	cargo check --locked -p deskbar-desktop
	pnpm --dir apps/desktop run check
	pnpm --dir apps/desktop run test
	pnpm --dir apps/desktop exec prettier --check src vite.config.ts
	cd apps/android && dart format --output=none --set-exit-if-changed lib test integration_test test_driver
	cd apps/android && flutter analyze
	cd apps/android && flutter test

test-android-connection:
	bash scripts/test_android_connection.sh "$(ANDROID_DEVICE)"
