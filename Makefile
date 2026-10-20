.DEFAULT_GOAL := help

PYTHON ?= python3
DOCS_PORT ?= 8765
ANDROID_DEVICE ?=
ENV_FILE ?= .env
export PUB_HOSTED_URL := https://pub.dev

.PHONY: help setup dev prototype android android-build android-release desktop-build check docs-check test-android-connection

help:
	@printf '%s\n' 'DeskBar — 电脑旁的工作台' '  make setup          安装依赖' '  make dev            启动本机服务端与连接助手' '  make android        运行 DeskBar 工作台（设置 ANDROID_DEVICE）' '  make check          文档与代码检查' '  make desktop-build  构建桌面开发版本' '  make android-build  构建 Android 开发 APK' '  make android-release 构建 arm64 签名 APK' '  make desktop-release 构建桌面安装和更新包' '  make release        同步版本、提交并创建本地 tag（V=vX.Y.Z）' '  make prototype      预览 HTML 布局原型'

setup:
	@test -f .env || cp .env.example .env
	pnpm install --frozen-lockfile
	cd apps/android && flutter pub get --enforce-lockfile

dev:
	@printf '%s\n' '启动 DeskBar 本机服务端与连接助手'
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

android-release:
	$(PYTHON) scripts/release.py check
	cd apps/android && flutter build apk --release --target-platform android-arm64

.PHONY: release release-check release-test desktop-release android-bundle
release:
	@ENV_FILE="$(ENV_FILE)" V="$(V)" $(PYTHON) scripts/release.py release

release-check:
	@ENV_FILE="$(ENV_FILE)" $(PYTHON) scripts/release.py check

release-test:
	$(PYTHON) -m unittest discover -s scripts -p 'test_release*.py'

desktop-release: release-check
	pnpm --dir apps/desktop run tauri build --config src-tauri/tauri.release.conf.json -- --locked

android-bundle: release-check
	cd apps/android && flutter build appbundle --release --target-platform android-arm64

docs-check:
	$(PYTHON) scripts/check_docs.py

check: docs-check release-check release-test
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
