APP_NAME := Stercorarius
BUILT_APP := .build/$(APP_NAME).app
INSTALLED_APP := $(HOME)/Applications/$(APP_NAME).app
BINARY := $(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)

.PHONY: build test lint app quit install uninstall

build:
	swift build -Xswiftc -warnings-as-errors

test:
	swift test -Xswiftc -warnings-as-errors
	Scripts/test-codex-hooks.sh

lint:
	swiftlint lint --strict --quiet
	swift format lint --strict --recursive Package.swift Sources Tests
	shellcheck Scripts/*.sh
	shfmt -d -i 2 Scripts

app:
	Scripts/build-app.sh

quit:
	@if pgrep -xq $(APP_NAME); then osascript -e 'quit app "$(APP_NAME)"'; fi

install: app quit
	mkdir -p $(HOME)/Applications
	ditto $(BUILT_APP) $(INSTALLED_APP)
	Scripts/codex-hooks.sh install $(BINARY)
	open $(INSTALLED_APP)

uninstall: quit
	Scripts/codex-hooks.sh uninstall $(BINARY)
	if [ -d $(INSTALLED_APP) ]; then trash $(INSTALLED_APP); fi
	if [ -d $(HOME)/.stercorarius ]; then trash $(HOME)/.stercorarius; fi
