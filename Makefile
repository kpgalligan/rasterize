APP := Rasterize
BUILD_DIR := build
APP_PATH := $(BUILD_DIR)/Build/Products/Release/$(APP).app

.PHONY: all app rust test lint typecheck project run clean

all: app

rust:
	cd core && cargo build --release

test:
	cd core && cargo test --release

lint:
	cd core && cargo clippy --all-targets -- -D warnings

project:
	xcodegen generate

app: rust project
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Release \
		-derivedDataPath $(BUILD_DIR) build

# Fast compile check of the Swift sources without a full Xcode build.
typecheck:
	swiftc -typecheck \
		-sdk "$$(xcrun --show-sdk-path --sdk macosx)" \
		-target arm64-apple-macos15.0 \
		-import-objc-header app/Bridging/Rasterize-Bridging-Header.h \
		app/Sources/*.swift

run: app
	open "$(APP_PATH)"

clean:
	rm -rf $(BUILD_DIR) $(APP).xcodeproj app/Info.plist
	cd core && cargo clean
