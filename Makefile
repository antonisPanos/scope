# One entry point for everyday tasks. Run `make` or `make help` to list them.
.DEFAULT_GOAL := help
.PHONY: help setup hooks build build-all test format lint testdisk install-dev devhook dmg release

DERIVED := build/DerivedData
XCB := xcodebuild -project Scope.xcodeproj -derivedDataPath $(DERIVED)

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

setup: hooks ## First-time setup: git hooks and Local.xcconfig
	@test -f Config/Local.xcconfig || { cp Config/Local.xcconfig.example Config/Local.xcconfig; echo "Created Config/Local.xcconfig: set your DEVELOPMENT_TEAM in it."; }

hooks: ## Install the git hooks from scripts/hooks
	git config core.hooksPath scripts/hooks
	@echo "Git hooks installed (scripts/hooks)."

build: ## Build Scope Dev (sandboxed, test disks only)
	$(XCB) -scheme "Scope Dev" build -quiet

build-all: ## Build all three schemes
	for s in "Scope Dev" "Scope Dev (No Sandbox)" "Scope"; do $(XCB) -scheme "$$s" build -quiet || exit 1; done

test: ## Run the engine tests
	cd Packages/ScopeEngine && swift test

format: ## Format Swift files changed from main (FILES=... to pick files, ALL=1 for everything)
	@files="$${FILES:-$$(if [ -n "$(ALL)" ]; then git ls-files '*.swift'; else git diff --name-only --diff-filter=ACMR origin/main -- '*.swift'; git ls-files --others --exclude-standard '*.swift'; fi)}"; \
	if [ -z "$$files" ]; then echo "No Swift files to format."; else xcrun swift-format format --in-place --configuration .swift-format $$files; fi

lint: ## Lint Swift files changed from main, like CI (needs: brew install swiftlint)
	@files="$${FILES:-$$(git diff --name-only --diff-filter=ACMR origin/main -- '*.swift'; git ls-files --others --exclude-standard '*.swift')}"; \
	if [ -z "$$files" ]; then echo "No Swift files to lint."; else \
	  xcrun swift-format lint --strict --configuration .swift-format $$files && swiftlint lint --quiet $$files; fi

testdisk: ## Create and mount the test disks (scripts/testdisk.sh create)
	scripts/testdisk.sh create

install-dev: ## Build Scope Dev and install it in ~/Applications
	scripts/install-dev.sh

dmg: ## Build a Release DMG into build/release (signed and notarized when set up)
	scripts/release.sh

release: ## Build the DMG for the tag at HEAD and attach it to its GitHub Release
	git fetch --tags
	scripts/release.sh --upload

devhook: ## Compile the devhook tool to build/devhook
	mkdir -p build && swiftc -O -o build/devhook scripts/devhook.swift
