# .github/workflows/ci.yml's format job names the same version; the two move together.
STYLUA_VERSION := 2.5.2

.PHONY: help test fmt fmt-check
help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## / : /'

test: ## Run every headless suite; the help-tags check runs when doc/ exists (tests/run.sh)
	bash tests/run.sh

fmt: ## Format every Lua file with the pinned StyLua
	bun x @johnnymorganz/stylua-bin@$(STYLUA_VERSION) lua plugin tests

fmt-check: ## Fail when a Lua file is not formatted (what the CI format job checks)
	bun x @johnnymorganz/stylua-bin@$(STYLUA_VERSION) --check lua plugin tests
