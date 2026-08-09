.PHONY: macos-generate macos-build macos-run macos-clean macos-reset-permission

BUNDLE_ID := net.sharkpp.doppelscreen

MACOS_DIR := apps/macos
MACOS_BUILD := $(MACOS_DIR)/build

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
	open $(MACOS_BUILD)/Build/Products/Debug/DoppelScreen.app

# 開発ビルドは ad-hoc 署名のため、リビルドのたびに TCC から別アプリとして扱われる。
# 許可が効かなくなったらこれで記録を消し、起動しなおして許可し直す。
macos-reset-permission:
	tccutil reset ScreenCapture $(BUNDLE_ID)
	defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "画面収録の許可をリセットしました。make macos-run で起動して許可し直してください。"

macos-clean:
	rm -rf $(MACOS_BUILD) $(MACOS_DIR)/DoppelScreen.xcodeproj
