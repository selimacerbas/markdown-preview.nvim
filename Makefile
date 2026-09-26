# The one StyLua pin: CI's format job runs make fmt-check, so no second copy
# of the version exists to drift from this one.
STYLUA_VERSION := 2.5.2
STYLUA := bun x @johnnymorganz/stylua-bin@$(STYLUA_VERSION)

.PHONY: help test test-browser hooks parity fmt fmt-check lint-text lint-blame shellcheck
help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## / : /'

# Both lanes run and their exits accumulate, so a red first lane does not
# hide the second.
test: ## Run every headless suite and, when doc/ exists, the help-tags check (tests/run.sh), then the commit-message policy test
	@rc=0; sh tests/run.sh || rc=1; sh tests/message_policy_test.sh || rc=1; exit $$rc

# Kept out of make test, which must run with no network and no browser.
# The Makefile is shared, so a repository with no browser test says so. It
# is the gate's definition, which the CI browser job runs: without the lock
# --frozen-lockfile resolves from the registry, and bun exits 0 when every
# test is skipped, so the JUnit report's counts rule (one test, none
# failed, none skipped).
test-browser: ## Run the browser smoke test (network: Playwright's Chromium and the page's CDN libraries)
	@test -d tests/browser || { echo 'test-browser: this repository has no browser test (tests/browser)' >&2; exit 2; }
	@command -v bun >/dev/null 2>&1 || { echo 'test-browser: bun runs the browser test and is not installed; install it from https://bun.sh' >&2; exit 1; }
	@test -f tests/browser/bun.lock || { echo 'test-browser: tests/browser/bun.lock is missing' >&2; exit 1; }
	cd tests/browser && bun install --frozen-lockfile
	@out=$$(mktemp -d) || exit 1; trap 'rm -rf "$$out"' EXIT; \
	(cd tests/browser && bun test --reporter=junit --reporter-outfile="$$out/smoke.xml") || exit 1; \
	line=$$(grep '<testsuites ' "$$out/smoke.xml") || { echo 'test-browser: the JUnit report has no testsuites line' >&2; exit 1; }; \
	for want in 'tests="1"' 'failures="0"' 'skipped="0"'; do \
		case $$line in *" $$want "*) ;; *) echo "test-browser: the smoke test report does not read $$want: $$line" >&2; exit 1 ;; esac; \
	done; echo "test-browser: $$line"

# Copied, never core.hooksPath: a hooks path inside the tracked tree runs the
# hooks a checked-out branch carries, a fork's post-checkout during the
# checkout itself. The policy is copied beside the hook, which runs that
# copy: git runs commit-msg for a merge with the merged tree checked out, so
# the tree's script would be the merged branch's. Run make hooks again after
# a policy change; the CI commits job judges the recorded message regardless.
hooks: ## Install the commit-msg hook and a copy of the message policy into this clone
	@hp=$$(git config --get core.hooksPath); \
	if [ -n "$$hp" ]; then \
	    echo "hooks: core.hooksPath is $$hp, so a hook copied into this clone would never run (git config --unset core.hooksPath, or --global --unset where it is set globally)" >&2; exit 1; \
	fi; \
	dir=$$(git rev-parse --git-path hooks) && mkdir -p "$$dir" \
	    && install -m 755 .githooks/message-policy "$$dir/message-policy" \
	    && install -m 755 .githooks/commit-msg "$$dir/commit-msg" && echo "hooks: installed $$dir/commit-msg and $$dir/message-policy"

# tests/parity.sh holds the list of the files the two plugins share. make
# exits 2 for any failed recipe, so the script's own codes (1 drifted, 2
# could not compare) show in its output or in a direct run.
parity: ## Compare the files shared with the sibling plugin (SIBLING=<its checkout>)
	@sh tests/parity.sh "$(SIBLING)"

# Tracked Lua files only, so an untracked directory (a live-server-rtp/
# checkout, node_modules/) never enters. StyLua exits 0 when it is handed no
# file, so an empty list fails here instead.
fmt: ## Format every tracked Lua file with the pinned StyLua
	@command -v bun >/dev/null 2>&1 || { echo 'fmt: bun runs StyLua and is not installed; install it from https://bun.sh' >&2; exit 1; }
	@[ -n "$$(git ls-files -- '*.lua')" ] || { echo 'fmt: git lists no tracked Lua file' >&2; exit 1; }
	git ls-files -z -- '*.lua' | xargs -0 $(STYLUA)

fmt-check: ## Fail when a tracked Lua file is not formatted (the CI format job runs this)
	@command -v bun >/dev/null 2>&1 || { echo 'fmt-check: bun runs StyLua and is not installed; install it from https://bun.sh' >&2; exit 1; }
	@[ -n "$$(git ls-files -- '*.lua')" ] || { echo 'fmt-check: git lists no tracked Lua file' >&2; exit 1; }
	@git ls-files -z -- '*.lua' | xargs -0 $(STYLUA) --check || { echo 'run make fmt to format' >&2; exit 1; }

# The character is built by printf, since make runs recipes under /bin/sh
# (dash on Ubuntu, which reads $'...' as literal text) and this file must not
# carry it. git grep searches the tracked files and keeps "none found" (1)
# apart from a failure (2 and up), which a grep under xargs folds together.
# README.md and doc/ are the docs sweep's; drop them from the exclusion when
# it lands.
lint-text: ## Refuse the em dash character in code, product copy and configuration
	@dash=$$(printf '\342\200\224'); \
	git grep -l -F -e "$$dash" -- . ':!README.md' ':!doc/'; rc=$$?; \
	if [ $$rc -eq 0 ]; then echo 'lint-text: the files above carry the em dash character' >&2; exit 1; fi; \
	if [ $$rc -ne 1 ]; then echo "lint-text: git grep failed (exit $$rc)" >&2; exit 1; fi

# The one list of the POSIX scripts, read as sh: a bashism passes bash and
# fails dash, Ubuntu's sh. SHELLCHECK names the binary, so the CI
# lint-workflows job runs this target with the pinned actionlint image's.
SHELLCHECK := shellcheck
shellcheck: ## Refuse a bashism in the hooks and the test scripts
	@command -v $(firstword $(SHELLCHECK)) >/dev/null 2>&1 || { echo 'shellcheck: $(firstword $(SHELLCHECK)) is not installed; install shellcheck (brew install shellcheck, or apt install shellcheck)' >&2; exit 1; }
	$(SHELLCHECK) -s sh .githooks/commit-msg .githooks/message-policy tests/*.sh

# git blame skips an entry that names no commit without a word, so a rebase
# that rewrote the format commit would leave the file ignoring nothing. Each
# entry must be a full commit name HEAD contains; read stops at a last line
# with no newline, which git blame still reads, so that line is read too.
lint-blame: ## Fail when .git-blame-ignore-revs names a commit HEAD does not contain
	@n=0; \
	while read -r sha rest || [ -n "$$sha" ]; do \
		case "$$sha" in ''|'#'*) continue ;; esac; \
		if [ "$$(git rev-parse --verify --quiet "$$sha^{commit}")" != "$$sha" ] \
			|| ! git merge-base --is-ancestor "$$sha" HEAD; then \
			echo "lint-blame: $$sha is not a full commit name HEAD contains" >&2; exit 1; \
		fi; \
		n=$$((n + 1)); \
	done < .git-blame-ignore-revs; \
	[ $$n -gt 0 ] || { echo 'lint-blame: .git-blame-ignore-revs names no commit' >&2; exit 1; }
