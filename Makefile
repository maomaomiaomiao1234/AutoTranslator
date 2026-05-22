.PHONY: build run release clean app app-release run-app

APP_NAME      := AutoTranslator
BUNDLE_ID     := com.local.AutoTranslator
INFO_PLIST    := Resources/Info.plist

DEBUG_BIN     := .build/debug/$(APP_NAME)
RELEASE_BIN   := .build/release/$(APP_NAME)

DEBUG_APP     := .build/debug/$(APP_NAME).app
RELEASE_APP   := .build/release/$(APP_NAME).app

build:
	swift build

run: build
	$(DEBUG_BIN)

release:
	swift build -c release

clean:
	swift package clean
	rm -rf .build

# 把 swift build 的产物打包成一个最小可用的 .app bundle。
# 用宏 $(call BUILD_APP,源二进制,目标APP路径) 在 debug/release 之间复用。
define BUILD_APP
	@echo "→ Packaging $(2)"
	@rm -rf "$(2)"
	@mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	@cp "$(1)" "$(2)/Contents/MacOS/$(APP_NAME)"
	@cp "$(INFO_PLIST)" "$(2)/Contents/Info.plist"
	@touch "$(2)"
	@codesign --force --deep --sign - "$(2)" >/dev/null 2>&1 || true
endef

# Debug bundle
app: build
	$(call BUILD_APP,$(DEBUG_BIN),$(DEBUG_APP))
	@echo "✓ $(DEBUG_APP)"

# Release bundle
app-release: release
	$(call BUILD_APP,$(RELEASE_BIN),$(RELEASE_APP))
	@echo "✓ $(RELEASE_APP)"

# 以 .app 形式运行（让通知/LSUIElement 行为正常）。
# `open -W` 阻塞直到 app 退出，方便 Ctrl+C 终止。
run-app: app
	open -W "$(DEBUG_APP)"
