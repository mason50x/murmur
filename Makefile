# Murmur. Run `make help` for the list.

.DEFAULT_GOAL := run
.PHONY: run app test release release-dry-run clean help

run: ## Build a development copy, install it over yours, and open it
	@scripts/build.sh

app: ## Build and sign build/Murmur.app without installing it
	@scripts/package.sh --dev

test: ## Run the unit tests
	@swift test

release: ## Ship everything since the last release, built in GitHub Actions (BUMP=patch|minor|major|X.Y.Z)
	@scripts/start-release.sh $(or $(BUMP),patch)

release-dry-run: ## Build and sign a release locally into dist/ (keys from 1Password); publishes nothing
	@scripts/release.sh $(or $(BUMP),patch) --dry-run

clean: ## Remove build output
	@rm -rf .build build dist

help: ## Show this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  make %-16s %s\n", $$1, $$2}'
