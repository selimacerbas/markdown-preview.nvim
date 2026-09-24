.PHONY: help test
help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## / : /'

test: ## Run every headless suite; the help-tags check runs when doc/ exists (tests/run.sh)
	bash tests/run.sh
