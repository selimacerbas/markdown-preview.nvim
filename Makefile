.PHONY: test
test: ## Run every headless suite; the help-tags check runs when doc/ exists (tests/run.sh)
	bash tests/run.sh
