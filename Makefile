# One entry point for everyday tasks. Run `make` or `make help` to list them.
.DEFAULT_GOAL := help
.PHONY: help setup hooks build build-all test app-test format lint install-dev devhook dmg release stress-prepare stress-reset stress-fill stress-open stress-run stress-low-space stress-report stress-status-client

DERIVED := build/DerivedData
XCB := xcodebuild -project Scope.xcodeproj -derivedDataPath $(DERIVED)

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

setup: hooks ## First-time setup: git hooks and Local.xcconfig
	@test -f Config/Local.xcconfig || { cp Config/Local.xcconfig.example Config/Local.xcconfig; echo "Created Config/Local.xcconfig: set your DEVELOPMENT_TEAM in it."; }

hooks: ## Install the git hooks from scripts/hooks
	git config core.hooksPath scripts/hooks
	git config blame.ignoreRevsFile .git-blame-ignore-revs
	@echo "Git hooks installed (scripts/hooks)."

build: ## Build Scope Dev (scratch mode, or explicit image-only stress mode)
	$(XCB) -scheme "Scope Dev" build -quiet

build-all: ## Build both schemes
	for s in "Scope Dev" "Scope"; do $(XCB) -scheme "$$s" build -quiet || exit 1; done

test: ## Run the engine tests
	cd Packages/ScopeEngine && swift test --no-parallel

app-test: ## Run the app's unit tests inside Scope Dev (ScopeTests/)
	$(XCB) -scheme "Scope Dev" test -only-testing:ScopeTests

format: ## Format Swift files changed from main (FILES=... to pick files, ALL=1 for everything)
	@files="$${FILES:-$$(if [ -n "$(ALL)" ]; then git ls-files '*.swift'; else git diff --name-only --diff-filter=ACMR origin/main -- '*.swift'; git ls-files --others --exclude-standard '*.swift'; fi)}"; \
	if [ -z "$$files" ]; then echo "No Swift files to format."; else xcrun swift-format format --in-place --configuration .swift-format $$files; fi

lint: ## Lint Swift files changed from main, like CI (needs: brew install swiftlint)
	@files="$${FILES:-$$(git diff --name-only --diff-filter=ACMR origin/main -- '*.swift'; git ls-files --others --exclude-standard '*.swift')}"; \
	if [ -z "$$files" ]; then echo "No Swift files to lint."; else \
	  xcrun swift-format lint --strict --configuration .swift-format $$files && swiftlint lint --quiet $$files; fi

install-dev: ## Build Scope Dev and install it in ~/Applications
	scripts/install-dev.sh

dmg: ## Build a Release DMG into build/release (signed and notarized when set up)
	scripts/release.sh

release: ## Build the DMG for the tag at HEAD and attach it to its GitHub Release
	git fetch --tags
	scripts/release.sh --upload

devhook: ## Compile the devhook tool to build/devhook
	mkdir -p build && swiftc -O -o build/devhook scripts/devhook.swift

stress-status-client: ## Compile the machine-readable stress status client
	mkdir -p build && swiftc -O -o build/stress_status scripts/stress_status.swift

stress-prepare: ## Create/mount and seed the 20 GB two-volume stress image
	/usr/bin/python3 scripts/stress_image.py prepare

stress-reset: ## Reset only verified fixtures inside the stress image
	/usr/bin/python3 scripts/stress_image.py reset

stress-fill: ## Leave about 1 GiB free for the low-space failure case
	/usr/bin/python3 scripts/stress_image.py fill

stress-open: build ## Open Scope Dev in verified image-only mode for manual QA
	/usr/bin/python3 scripts/stress_image.py open

stress-run: build devhook stress-status-client ## Run three Scope Dev stress repetitions
	/usr/bin/python3 scripts/stress_run.py run

stress-low-space: build devhook stress-status-client ## Verify a near-full image fails safely, then reset it
	/usr/bin/python3 scripts/stress_run.py low-space

stress-report: ## Report medians and compare with the recorded baseline
	/usr/bin/python3 scripts/stress_run.py report
