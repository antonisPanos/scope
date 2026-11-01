# One entry point for everyday tasks. Run `make` or `make help` to list them.
.DEFAULT_GOAL := help
.PHONY: help setup hooks build build-all test testdisk install-dev devhook

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

testdisk: ## Create and mount the test disks (scripts/testdisk.sh create)
	scripts/testdisk.sh create

install-dev: ## Build Scope Dev and install it in ~/Applications
	scripts/install-dev.sh

devhook: ## Compile the devhook tool to build/devhook
	mkdir -p build && swiftc -O -o build/devhook scripts/devhook.swift
