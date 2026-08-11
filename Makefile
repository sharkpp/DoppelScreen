.PHONY: macos-dev-certificate macos-generate macos-build macos-run macos-selftest macos-serve macos-clean macos-reset-permission latency-clock web-install web-build web-test e2e

BUNDLE_ID := net.sharkpp.doppelscreen

MACOS_DIR := apps/macos
WEB_DIR := apps/web
MACOS_BUILD := $(MACOS_DIR)/build
MACOS_APP := $(MACOS_BUILD)/Build/Products/Debug/DoppelScreen.app

SELFTEST_DIR := $(MACOS_BUILD)/selftest
# 例: make macos-selftest SELFTEST_ARGS="--display 1 --duration 5"
SELFTEST_ARGS ?=

# 開発ビルド用のコード署名証明書を作る。初回のみ実行する。
# これがないと ad-hoc 署名になり、リビルドのたびに画面収録の許可が失効する。
macos-dev-certificate:
	@$(MACOS_DIR)/scripts/create-dev-certificate.sh

macos-generate:
	cd $(MACOS_DIR) && xcodegen generate

macos-build: macos-generate
	@xcodebuild -project $(MACOS_DIR)/DoppelScreen.xcodeproj \
		-scheme DoppelScreen \
		-configuration Debug \
		-derivedDataPath $(MACOS_BUILD) \
		-quiet \
		build

macos-run: macos-build
	open $(MACOS_APP)

# UI を出さずにキャプチャを一通り走らせ、結果を JSON と PNG で残す。
# TCC は「責任プロセス」で許諾を判定するため、ターミナルから実行ファイルを直接叩かず
# `open` で起動する（直接叩くとターミナルの許諾が参照されて実態と食い違う）。
# 検証モードは NSApplication を起動しないので LaunchServices が追跡できず `open -W` は使えない。
# レポートの出現を待つ。
macos-selftest: macos-build
	@rm -rf $(SELFTEST_DIR)
	@mkdir -p $(SELFTEST_DIR)
	@open -n -a "$(abspath $(MACOS_APP))" --args --selftest --output "$(abspath $(SELFTEST_DIR))" $(SELFTEST_ARGS)
	@count=0; until [ -f $(SELFTEST_DIR)/report.json ]; do \
		count=$$((count + 1)); \
		if [ $$count -gt 60 ]; then echo "セルフテストが応答しません"; exit 1; fi; \
		sleep 1; \
	done
	@cat $(SELFTEST_DIR)/report.json
	@grep -q '"ok"[[:space:]]*:[[:space:]]*true' $(SELFTEST_DIR)/report.json

# 実際の配信経路（キャプチャ → LocalServer → PeerTransport）を立ち上げ、
# ビューアの接続を待つ。接続先は build/selftest/serve.json に出る。
# 例: make macos-serve SELFTEST_ARGS="--duration 120"
macos-serve: macos-build
	@rm -rf $(SELFTEST_DIR)
	@mkdir -p $(SELFTEST_DIR)
	@open -n -a "$(abspath $(MACOS_APP))" --args --selftest --serve --output "$(abspath $(SELFTEST_DIR))" $(SELFTEST_ARGS)
	@count=0; until [ -f $(SELFTEST_DIR)/serve.json ]; do \
		count=$$((count + 1)); \
		if [ $$count -gt 30 ]; then echo "待受が始まりません"; exit 1; fi; \
		sleep 1; \
	done
	@cat $(SELFTEST_DIR)/serve.json

# glass-to-glass の実測用（SPEC.md §3.3）。ホスト画面にミリ秒カウンタを出し、
# ホストとビューアを 1 台のカメラで同時に高速度撮影して差分を読む。
# 手順と記録は docs/latency-measurements.md。
latency-clock:
	@echo "手順と記録先: docs/latency-measurements.md"
	@echo "開いたページを全画面にしてから撮影してください。"
	open docs/latency-clock.html

web-install:
	npm --prefix $(WEB_DIR) install

web-build:
	npm --prefix $(WEB_DIR) run build

web-test:
	npm --prefix $(WEB_DIR) run test

# ホストを起動して実 Chrome から繋ぎ、映像が出るところまでを通しで確認する。
# Playwright 同梱の Chromium は H.264 を持たないため、実 Chrome を使う。
e2e: macos-build
	npm --prefix $(WEB_DIR) run e2e

# 開発ビルドは ad-hoc 署名のため、リビルドのたびに TCC から別アプリとして扱われる。
# 許可が効かなくなったらこれで記録を消し、起動しなおして許可し直す。
macos-reset-permission:
	tccutil reset ScreenCapture $(BUNDLE_ID)
	defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "画面収録の許可をリセットしました。make macos-run で起動して許可し直してください。"

macos-clean:
	rm -rf $(MACOS_BUILD) $(MACOS_DIR)/DoppelScreen.xcodeproj $(WEB_DIR)/dist
