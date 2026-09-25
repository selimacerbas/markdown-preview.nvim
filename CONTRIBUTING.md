# Contributing

Issues and PRs are welcome. This file names the commands the CI runs so a green PR is a local run away: `make test`, `make fmt-check`, `make lint-text` and `make lint-blame` run here as they run in CI, while the floor (Neovim 0.10.0), below-floor (Neovim 0.9.5), windows and upstream (live-server.nvim `main`) jobs run only in CI.

You need Neovim 0.10 or newer, a live-server.nvim checkout (found as below), curl for the three suites that make HTTP requests, and bun for the formatter.

## Run the tests

    make test

runs every suite through `tests/run.sh`, the same loop CI runs. Each suite is a plain Lua file under `tests/` that runs headless and exits 1 on any failure, so one can be run alone:

    nvim --headless -u NONE -l tests/token_auth_test.lua

`tests/helpers.lua` finds live-server.nvim at `$LIVE_SERVER_RTP`, `./live-server-rtp` or `../live-server.nvim`, in that order, and isolates the run from your own Neovim cache.

## Format

    make fmt        # StyLua, the version pinned in the Makefile; bun is the one prerequisite (make fmt-check is what CI runs; make lint-text and make lint-blame are the other gates; make test runs the suites)

The config is `.stylua.toml`. The one-time format commit is listed in `.git-blame-ignore-revs` (`git config blame.ignoreRevsFile .git-blame-ignore-revs`).

## Commits

Plain imperative subject of at most 72 characters; the body, wrapped at 72 columns, says why. No attribution trailers: a commit names its author alone. No em dash character (U+2014) either; `make lint-text` refuses it in the files it checks. On a pull request CI refuses a commit that carries either, and a title that carries the character or runs over 72 characters, since the title becomes the subject of a merge or squash commit; on a push to main it reports them. To refuse both locally: `git config core.hooksPath .githooks`.

## Releases (maintainer)

1. Move the `Unreleased` section of `CHANGELOG.md` under the new version and date, add the version's link definition at the end, and start the `[Unreleased]` compare link at the new tag.
2. `git tag -a vX.Y.Z -m "vX.Y.Z"` (annotated, so `git describe` works), `git push origin vX.Y.Z`.
3. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <the section as a file>`.
