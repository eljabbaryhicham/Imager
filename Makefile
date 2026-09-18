APP_NAME := Imager
BUILD_DIR := build
CONFIGURATION := release

.PHONY: build app run clean

build:
	swift build -c $(CONFIGURATION)

app: build
	rm -rf $(BUILD_DIR)/$(APP_NAME).app
	mkdir -p $(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS
	mkdir -p $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources
	cp .build/$(CONFIGURATION)/$(APP_NAME) $(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/
	cp Resources/Info.plist $(BUILD_DIR)/$(APP_NAME).app/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources/
	codesign --force --sign - $(BUILD_DIR)/$(APP_NAME).app >/dev/null 2>&1 || true

run: app
	open $(BUILD_DIR)/$(APP_NAME).app

clean:
	rm -rf .build $(BUILD_DIR)