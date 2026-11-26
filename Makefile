# Troy: build, test, package and install.
PREFIX_APP ?= /Applications
PREFIX_BIN ?= $(HOME)/.local/bin
APP_NAME   := Troy.app
BUILD_APP  := build/$(APP_NAME)

.PHONY: build test smoke app run install uninstall clean icon screenshots

build:
	swift build -c release

test:
	swift test

# Drives the built MCP server over real pipes, in both protocol generations.
smoke:
	swift build --product troy
	python3 Scripts/smoke-mcp.py .build/debug/troy

app:
	Scripts/build-app.sh

run: app
	open "$(BUILD_APP)"

# Copies the app and links the command line tool to the helper inside it.
install: app
	@set -e; \
	mkdir -p "$(PREFIX_APP)" "$(PREFIX_BIN)"; \
	rm -rf "$(PREFIX_APP)/$(APP_NAME)"; \
	ditto "$(BUILD_APP)" "$(PREFIX_APP)/$(APP_NAME)"; \
	ln -sfn "$(PREFIX_APP)/$(APP_NAME)/Contents/Helpers/troy" "$(PREFIX_BIN)/troy"; \
	echo ""; \
	echo "Installed $(PREFIX_APP)/$(APP_NAME)"; \
	echo "Linked    $(PREFIX_BIN)/troy"; \
	echo ""; \
	echo "Next: run 'troy connect' to set up your AI client (Claude Code, Codex, ...)."; \
	case ":$$PATH:" in \
	  *":$(PREFIX_BIN):"*) ;; \
	  *) echo ""; \
	     echo "Warning: $(PREFIX_BIN) is not on your PATH."; \
	     echo "Add it, for example: export PATH=\"$(PREFIX_BIN):\$$PATH\"" ;; \
	esac

# Removes exactly what install created. Never touches the database.
uninstall:
	@set -e; \
	if [ -L "$(PREFIX_BIN)/troy" ]; then rm "$(PREFIX_BIN)/troy"; echo "Removed $(PREFIX_BIN)/troy"; fi; \
	if [ -d "$(PREFIX_APP)/$(APP_NAME)" ]; then rm -rf "$(PREFIX_APP)/$(APP_NAME)"; echo "Removed $(PREFIX_APP)/$(APP_NAME)"; fi; \
	echo "Your data (~/Library/Application Support/Troy) was not touched."

clean:
	rm -rf build .build

icon:
	swift Scripts/make-icon.swift Resources/Troy.icns Resources/AppIcon-1024.png

# Regenerates docs/images from real windows. Needs Screen Recording permission for this terminal.
screenshots:
	swift build
	python3 Scripts/screenshots.py
