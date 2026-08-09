.PHONY: macos-dev-certificate macos-generate macos-build macos-run macos-selftest macos-clean macos-reset-permission

BUNDLE_ID := net.sharkpp.doppelscreen

MACOS_DIR := apps/macos
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

# 開発ビルドは ad-hoc 署名のため、リビルドのたびに TCC から別アプリとして扱われる。
# 許可が効かなくなったらこれで記録を消し、起動しなおして許可し直す。
macos-reset-permission:
	tccutil reset ScreenCapture $(BUNDLE_ID)
	defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "画面収録の許可をリセットしました。make macos-run で起動して許可し直してください。"

macos-clean:
	rm -rf $(MACOS_BUILD) $(MACOS_DIR)/DoppelScreen.xcodeproj
