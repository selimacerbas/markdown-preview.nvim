# Contributing

Issues and PRs are welcome. This file names the commands the CI runs so a green PR is a local run away.

## Run the tests

    make test

runs every suite through `tests/run.sh`, the same loop CI runs. Each suite is a plain Lua file under `tests/` that runs headless and exits 1 on any failure, so one can be run alone:

    nvim --headless -u NONE -l tests/token_auth_test.lua

`tests/helpers.lua` finds live-server.nvim at `$LIVE_SERVER_RTP`, `./live-server-rtp` or `../live-server.nvim`, in that order, and isolates the run from your own Neovim cache.

## Format

    make fmt        # StyLua, the version pinned in the Makefile; bun is the one prerequisite (make fmt-check is what CI runs; make lint-text and make lint-blame are the other gates; make test runs the suites)

The config is `.stylua.toml`. The one-time format commit is listed in `.git-blame-ignore-revs` (`git config blame.ignoreRevsFile .git-blame-ignore-revs`).

## Commits

Plain imperative subject of at most 72 characters; the body, wrapped at 72 columns, says why. No attribution trailers: the maintainer authors every commit, and CI rejects a `Co-Authored-By` line. No em dash character (U+2014) either: `make lint-text` refuses it in the files it checks, and CI refuses it in a commit message. To refuse both locally: `git config core.hooksPath .githooks`.

## Releases (maintainer)

1. Move the `Unreleased` section of `CHANGELOG.md` under the new version and date.
2. `git tag -a vX.Y.Z -m "vX.Y.Z"` (annotated, so `git describe` works), `git push origin vX.Y.Z`.
3. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <the section as a file>`.
