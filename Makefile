# Cocut — local build helpers. Requires Xcode and `brew install xcodegen`.

SHELL   := /bin/bash
PROJECT := Cocut.xcodeproj
SCHEME  := Cocut
APP     := build/Build/Products/Release/Cocut.app

.PHONY: project open build run install clean

## Generate the Xcode project from project.yml
project:
	xcodegen

## Generate and open in Xcode
open: project
	open $(PROJECT)

## Command-line Release build (signed with your Xcode team if one is set, else ad-hoc)
build: project
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath build \
		-allowProvisioningUpdates build | (command -v xcbeautify >/dev/null && xcbeautify || cat)

## Build and launch
run: build
	open "$(APP)"

## Build and copy into /Applications
install: build
	rm -rf "/Applications/Cocut.app"
	cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/Cocut.app"

clean:
	rm -rf build $(PROJECT)
