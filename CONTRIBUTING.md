# Contributing

Issues and PRs are welcome. This file names the commands the CI runs so a green PR is a local run away: `make test`, `make fmt-check`, `make lint-text` and `make lint-blame` run here as they run in CI. The `lint-workflows` job also runs actionlint, which no make target wraps: run `actionlint .github/workflows/*.yml` locally (`brew install actionlint`, or a binary from <https://github.com/rhysd/actionlint/releases>). The `floor` (Neovim 0.10.0), `floor-below` (Neovim 0.9.5), `windows`, `upstream` (live-server.nvim `main`) and `commits` jobs run only in CI; the commit-msg hook below runs the `commits` job's policy locally.

You need Neovim 0.10 or newer, a live-server.nvim checkout (found as below), curl for the three suites that make HTTP requests, and bun for the formatter.

## Run the tests

    make test

runs every suite through `tests/run.sh`, the same loop CI runs, and then `tests/message_policy_test.sh`, which commits in a scratch repository through the hook (`sh tests/message_policy_test.sh` alone). Each suite is a plain Lua file under `tests/` that runs headless and exits 1 on any failure, so one can be run alone:

    nvim --headless -u NONE -l tests/token_auth_test.lua

`tests/helpers.lua` finds live-server.nvim at `$LIVE_SERVER_RTP`, `./live-server-rtp` or `../live-server.nvim`, in that order, and isolates the run from your own Neovim cache.

## Format

    make fmt        # StyLua, the version pinned in the Makefile; bun is the one prerequisite (make fmt-check is what CI runs; make lint-text and make lint-blame are the other gates; make test runs the suites)

The config is `.stylua.toml`. The one-time format commit is listed in `.git-blame-ignore-revs` (`git config blame.ignoreRevsFile .git-blame-ignore-revs`).

## Commits

Plain imperative subject of at most 72 characters; the body, wrapped at 72 columns, says why. A commit names its author alone.

`.githooks/message-policy` refuses a message that carries any of:

- the em dash character (U+2014);
- an attribution trailer: `Co-authored-by`, `Signed-off-by`, `Co-developed-by`, `Assisted-by`, `Generated-by`, `Reviewed-by`, `Acked-by`, `Tested-by`, `Suggested-by` or `Reported-by`, in any case and with or without blanks before the colon, as git reads a trailer;
- a workflow skip instruction: `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `[actions skip]`, in any case; one on main leaves that push with no CI run.

The policy runs in three places. The commit-msg hook runs it on each commit you make. On a pull request the `commits` job refuses a title, a body or a commit that breaks it: the title and the body become the squash commit on main, and the title is at most 65 characters, since ` (#N)` is appended to it. On a push to main the same job reports what landed; it cannot refuse it. `make lint-text` refuses the em dash in the tracked files it checks.

Install the hook with `make hooks`, which copies it into this clone's hooks directory. `git config core.hooksPath .githooks` is not the way: a hooks path inside the tracked tree runs whatever hooks a checked-out branch carries, a fork's included, during the checkout itself, before anyone has read them; the copied hook runs this tree's policy only when you commit. `make hooks` refuses while `core.hooksPath` is set; `git config --unset core.hooksPath` clears it.

When the `commits` job is red on your pull request, reword the commit (`git commit --amend` for the last one, `git rebase -i` for an earlier one) or edit the title or the body, then force-push the branch. A red report on main is a record and is left alone; the next push judges only its own range. Accepting a review suggestion in GitHub's web UI adds a `Co-authored-by` line for the suggester, so apply suggestions locally instead.

## Releases (maintainer)

1. Move the `Unreleased` section of `CHANGELOG.md` under the new version and date, add the version's link definition under `[Unreleased]`'s (newest first), and start the `[Unreleased]` compare link at the new tag.
2. Tag only a commit whose `ci-ok` is green (`gh run list --commit <sha>`): `git tag -a vX.Y.Z -m "vX.Y.Z"`, `git push origin vX.Y.Z`. The tags v1.0.0 to v1.2.1 are annotated and v1.3.0 to v1.10.0 are lightweight, so `git describe` needs `--tags` until the next annotated tag.
3. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <the section as a file>`.
