APP_NAME  := NotchBar.app
DEST      := $(HOME)/Applications
HOOK      := $(DEST)/$(APP_NAME)/Contents/MacOS/notchbar-hook

.PHONY: all build install uninstall run clean test dist

all: build

build:
	@./scripts/build.sh

install: build
	@mkdir -p "$(DEST)"
	@pkill -x NotchBar 2>/dev/null; sleep 0.3; true
	@rm -rf "$(DEST)/$(APP_NAME)"
	@cp -R "build/$(APP_NAME)" "$(DEST)/"
	@"$(HOOK)" install claude $$([ -d "$(HOME)/.codex" ] && echo codex) $$([ -d "$(HOME)/.cursor" ] && echo cursor)
	@open "$(DEST)/$(APP_NAME)"
	@echo "NotchBar installed to $(DEST)/$(APP_NAME) and running."

uninstall:
	@if [ -x "$(HOOK)" ]; then "$(HOOK)" uninstall claude codex cursor; fi
	@pkill -x NotchBar 2>/dev/null; true
	@rm -rf "$(DEST)/$(APP_NAME)"
	@echo "NotchBar removed."

run: build
	@pkill -x NotchBar 2>/dev/null; sleep 0.3; open build/$(APP_NAME)

test:
	swift test

dist:
	@./scripts/dist.sh

clean:
	rm -rf .build build dist
