.PHONY: macos-generate macos-build macos-run macos-clean

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

macos-clean:
	rm -rf $(MACOS_BUILD) $(MACOS_DIR)/DoppelScreen.xcodeproj
