APP         = build/AviaCalls.app
BINARY      = .build/release/AviaCalls
APP_VERSION ?= 0.0.0-dev
# «-» — ad-hoc подпись для раздачи; для своей машины: make app SIGN="Apple Development"
# (с ad-hoc подписью macOS после каждой сборки забывает выданные разрешения).
SIGN        ?= -
# Релизные сборки получают SU_FEED_URL и SPARKLE_PUB_KEY — включается автообновление.
SU_FEED_URL ?=
SPARKLE_PUB_KEY ?=

.PHONY: app zip run test clean icon

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(APP_VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(APP_VERSION)" $(APP)/Contents/Info.plist
	plutil -insert CFBundleIconFile -string AppIcon $(APP)/Contents/Info.plist
	@if [ -n "$(SU_FEED_URL)" ]; then plutil -replace SUFeedURL -string "$(SU_FEED_URL)" $(APP)/Contents/Info.plist; fi
	@if [ -n "$(SPARKLE_PUB_KEY)" ]; then plutil -replace SUPublicEDKey -string "$(SPARKLE_PUB_KEY)" $(APP)/Contents/Info.plist; fi
	cp $(BINARY) $(APP)/Contents/MacOS/AviaCalls
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	# ресурсы зависимостей: на этой машине они нашлись бы и по пути сборки, у коллег — нет
	for b in .build/release/*.bundle; do [ -d "$$b" ] && cp -R "$$b" $(APP)/Contents/Resources/ || true; done
	@FW=$$(find .build/artifacts -type d -name Sparkle.framework | head -1); \
	if [ -n "$$FW" ]; then cp -R "$$FW" $(APP)/Contents/Frameworks/; else echo "warning: Sparkle.framework not found"; exit 1; fi
	codesign --force --deep --sign "$(SIGN)" $(APP)
	@echo "Built $(APP) ($(APP_VERSION))"

zip: app
	rm -f build/AviaCalls.zip
	ditto -c -k --keepParent $(APP) build/AviaCalls.zip
	@ls -la build/AviaCalls.zip

run: app
	open $(APP)

test:
	swift test

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
