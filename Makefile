PROJECT := Rolodex.xcodeproj
SCHEME := Rolodex
APP_NAME := Rolodex
BUILD_DIR := build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
DEV_CONFIGURATION := Debug
RELEASE_CONFIGURATION := Release
INSTALL_DIR := /Applications

# Dev builds are signed ad hoc so they don't depend on a developer certificate
# (the entitlements are still embedded). Release builds keep the project's signing.
DEV_SIGNING := CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

APP_PATH_DEV := $(DERIVED_DATA)/Build/Products/$(DEV_CONFIGURATION)/$(APP_NAME).app
APP_PATH_RELEASE := $(DERIVED_DATA)/Build/Products/$(RELEASE_CONFIGURATION)/$(APP_NAME).app

.PHONY: all help setup dev build clean open close install uninstall reinstall test

## Default target: same as `make setup` then `make dev`.
all: setup dev

## Help for all commands, grouped by category.
help:
	@echo "Rolodex"
	@echo ""
	@echo "Everyday development:"
	@echo "  make dev        Build for development and open it (clean, build, open)"
	@echo "  make open       Open the already-built dev app"
	@echo "  make close      Kill the running app (native app only)"
	@echo "  make clean      Kill the running app and remove build artifacts"
	@echo "  make test       Run unit tests"
	@echo ""
	@echo "Production / distribution:"
	@echo "  make build      Build for production (Release)"
	@echo "  make install    Build for production and install to $(INSTALL_DIR)"
	@echo "  make uninstall  Close the app and remove it from $(INSTALL_DIR)"
	@echo "  make reinstall  make uninstall, then make install"
	@echo ""
	@echo "Environment:"
	@echo "  make setup      Set up the environment if needed"
	@echo "  make all        Same as: make setup && make dev (default target)"
	@echo "  make help       Show this help"

## Set up the environment if needed (verify Xcode is available).
setup:
	@command -v xcodebuild >/dev/null 2>&1 || { \
		echo "xcodebuild not found. Install Xcode from the App Store, then run:"; \
		echo "  sudo xcode-select -s /Applications/Xcode.app"; \
		exit 1; \
	}
	@mkdir -p "$(BUILD_DIR)"
	@echo "Environment OK."

## Build for development and open it.
dev: clean
	@echo "Building $(APP_NAME) ($(DEV_CONFIGURATION))..."
	@n=1; \
	until xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(DEV_CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) $(DEV_SIGNING) build; do \
		if [ $$n -ge 4 ]; then \
			echo "Build failed after $$n attempts."; \
			exit 1; \
		fi; \
		echo "Build failed (attempt $$n), retrying (Swift macro plugin server is occasionally flaky)..."; \
		n=$$((n + 1)); \
		sleep 5; \
	done
	@$(MAKE) --no-print-directory open

## Build for production.
build:
	@echo "Building $(APP_NAME) ($(RELEASE_CONFIGURATION))..."
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(RELEASE_CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) build

## Kill the app and remove build artifacts.
clean:
	@pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true
	@rm -rf "$(DERIVED_DATA)"
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true
	@echo "Cleaned."

## Open dev app.
open:
	@if [ -d "$(APP_PATH_DEV)" ]; then \
		open "$(APP_PATH_DEV)"; \
	else \
		echo "No dev build found at $(APP_PATH_DEV). Run 'make dev' first."; \
		exit 1; \
	fi

## Kill the app. Only if native.
close:
	@pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true

## Build for production and install to /Applications.
install: build
	@echo "Installing $(APP_NAME) to $(INSTALL_DIR)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_PATH_RELEASE)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

## make close. Remove if installed.
uninstall: close
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Removed $(INSTALL_DIR)/$(APP_NAME).app (if present)"

## make uninstall, make install.
reinstall: uninstall install

## Run contact-loading regression tests, plus any Xcode test target.
test:
	@mkdir -p "$(BUILD_DIR)/Tests"
	@xcrun swiftc -parse-as-library \
		Rolodex/Models/SmartGroup.swift Rolodex/Models/ContactDraft.swift Rolodex/Extensions/CNContact+Rolodex.swift \
		Rolodex/Persistence/AppDataStore.swift Rolodex/Persistence/ContactHistoryStore.swift Rolodex/Services/ContactsService.swift \
		Rolodex/ViewModels/ContactsViewModel.swift Tests/ContactsPerformanceTests.swift \
		-o "$(BUILD_DIR)/Tests/ContactsPerformanceTests"
	@"$(BUILD_DIR)/Tests/ContactsPerformanceTests"
	@if ! xcodebuild -list -project $(PROJECT) 2>/dev/null | grep -q "Tests"; then \
		echo "No additional Xcode test target configured."; \
	else \
		xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' test; \
	fi
