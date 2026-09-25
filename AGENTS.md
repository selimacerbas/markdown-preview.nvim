# markdown-preview.nvim: agent operating file

Neovim plugin for live markdown preview in the browser. Pure Lua, no npm. This file is the index for any coding agent and the source of truth for how to work here; CLAUDE.md includes it. The README is the user's contract and CHANGELOG.md the record of what shipped.

## Structure

- `lua/markdown_preview/init.lua`: setup and config, server lifecycle, refresh, scroll sync, mermaid pre-rendering
- `lua/markdown_preview/floor.lua`: the Neovim requirement and its message, the one source the plugin file and the module read
- `lua/markdown_preview/util.lua`: fs helpers, workspace resolution, asset resolution, browser open
- `lua/markdown_preview/ts.lua`: Tree-sitter mermaid extractor plus a Lua-pattern fallback
- `lua/markdown_preview/lock.lua`: the takeover-mode lock file (port, workspace, pid, token; mode 0600)
- `lua/markdown_preview/remote.lua`: HTTP event injection for secondary instances (scroll sync)
- `plugin/markdown-preview.lua`: the floor check and the user commands (`:MarkdownPreview`, `:MarkdownPreviewRefresh`, `:MarkdownPreviewStop`)
- `assets/index.html`: the browser preview app (CSS plus JS, one file)
- `lazy.lua`: the spec lazy.nvim reads from this plugin, listing live-server.nvim alone; it stays in step with the README's lazy.nvim snippet
- `tests/`: the headless suites, `helpers.lua` (the harness), `run.sh` (the runner) and `floor_smoke.sh` (the below-floor smoke)

## Sibling dependency

- live-server.nvim (`selimacerbas/live-server.nvim`, cloned beside this repo as `../live-server.nvim`) is the pure Lua HTTP server with SSE this plugin drives; one maintainer edits both, and commits stay per repo.
- The live-server floor is v1.5.0 in three places that move together: `H.live_server_floor` in `tests/helpers.lua`, and `LIVE_SERVER_FLOOR` and `LIVE_SERVER_FLOOR_SHA` in `.github/workflows/ci.yml`; the workflow's `live-server floor is the pinned tag` step reds when they disagree, and the gating test jobs run on that commit.
- live-server exports `require("live_server.server").features` (`token_auth`, `host_binding`, `asset_route`); the plugin reads `asset_route` and warns once when it is missing.
- APIs used: `server.start(cfg)` (an instance with `.port`), `server.stop(inst)`, `server.reload(inst, path)`, `server.send_event(inst, event, data)`, `server.update_target(inst, root, index)`, `server.connected_client_count(inst)`.
- Endpoints used: `GET /__live/inject?event=<type>&data=<json>&t=<token>` (remote.lua) and `GET /__live/asset?p=<relpath>&t=<token>` (the preview page).

## Architecture

- Neovim writes the buffer to `content.md` in a workspace directory, by default (`workspace_dir` unset) under `stdpath("cache")/markdown-preview/`; live-server serves it and pushes SSE events (`reload` on change, `scroll` with the cursor line).
- The browser renders with markdown-it, highlight.js, KaTeX and mermaid (loaded from CDNs) and diffs the DOM with morphdom.
- Auth: a per-session token gates `content.md`, the `asset_root` sidecar, the SSE stream, the inject endpoint and the asset route; on a non-loopback `host` the index page is gated too and carries no token, which the browser takes from the `?t=` URL.
- Instance modes: `takeover` (the default; one shared workspace, port 8421 under the default `port = 0`, a lock file elects the primary) and `multi` (a per-buffer workspace, or `workspace_dir` when set, and a server per instance on an OS-assigned port under the default `port = 0`).
- `mermaid_renderer = "rust"` pre-renders mermaid fences through the `mmdr` CLI; the default renders them in the browser.

## Conventions

- Neovim 0.10 or newer: `lua/markdown_preview/floor.lua` states the requirement and the message once, below it the plugin file and the module stop with that message, and CI proves the refusal on a real Neovim 0.9.5 with `tests/floor_smoke.sh`.
- `vim.uv` for async I/O; Lua patterns, never regex quantifiers.
- StyLua 2.5.2 with `.stylua.toml` (tabs, 120 columns); the Makefile pins the version, and bun is the formatter's one prerequisite.
- Gates by make target: `make fmt` (writes), `make fmt-check`, `make lint-text` (the em dash), `make lint-blame` (`.git-blame-ignore-revs`), `make test`; `make help` lists them.
- CI runs the same targets: `make fmt-check`, `make lint-text` and `make lint-blame` as written, and `tests/run.sh`, the script `make test` runs, in the test, floor, upstream, windows and nightly jobs.
- No default keymaps (issue #4). No em dash character anywhere.
- Commits: subject at most 72 characters, a body that says why, no attribution trailer; `git config core.hooksPath .githooks` turns on the hook that refuses a trailer and the em dash.
- Release titles are clean version numbers (`v1.10.0`); the notes come from the version's section of `CHANGELOG.md`.

## Tests

- `make test` runs `tests/run.sh`: every `tests/*_test.lua` under private XDG directories, then the help tags when `doc/` exists.
- One suite alone: `nvim --headless -u NONE -l tests/<file>_test.lua`.
- `helpers_test`: the harness itself (root and isolation, the bounded curl, exit rulings, callback errors, `H.expect_error`, `H.rtp`, path spelling).
- `parse_test`: every tracked Lua file parses under this Neovim's LuaJIT (it needs a git checkout).
- `rtp_test`: how `H.rtp()` proves the checkout and chooses live-server.nvim, and what it refuses.
- `token_auth_test`: the token reaches the served page and gates `content.md`, and the lock file that holds it is private.
- `asset_route_test`: the installed live-server exports `asset_route`, the route serves files beside the document, and the sidecar is gated.
- `floor_guard_test`: below 0.10 every documented command refuses with the floor message; at the floor the commands are defined.
- `tests/floor_smoke.sh`: the refusal on a real Neovim below the floor; CI runs it on 0.9.5, and locally such a Neovim goes first on PATH.
- curl is needed by the three suites that make HTTP requests (`helpers_test`, `token_auth_test`, `asset_route_test`).

## Test harness contract

- `tests/helpers.lua` is one source with live-server.nvim's copy outside its `H.rtp` region and the `H.live_server_floor` block, indentation aside (tabs here, 4 spaces there); live-server's copy is the source, so a change lands there first.
- Isolation: `tests/run.sh` points the four XDG directories at a private `mktemp -d` before Neovim starts (a caller's exported one is kept), and `H.isolate()` moves cache, data and state again before the suite loads the plugin, failing loud when `stdpath()` does not follow.
- Lookup: `H.rtp()` takes `$LIVE_SERVER_RTP`, then `./live-server-rtp` (the CI checkout), then `../live-server.nvim`; a set `LIVE_SERVER_RTP` (empty reads as unset) that is not a directory raises instead of falling through, otherwise the first that exists wins, and finding none raises.
- Proof: every module of this plugin, and live-server's `server` and `util` (the modules the plugin loads, as the pinned floor ships them), must resolve from the chosen entries, or the suite raises instead of loading an installed copy.
- One canonical path form: `H.canon` gives a path one spelling (absolute, links resolved, forward slashes), and `H.same_path` compares two, folding case where `H.fs_folds_case` measured that the filesystem folds it.
- Exit rulings: the exit code is the ruling; a red suite, one that ends without `H.finish()`, and one whose callback raised exit 1, whatever the suite's own quits, `os.exit` calls and callbacks do.
- Every ledger line is written as a line by `H.write_line` (straight to stdout, its own newline), and `tests/run.sh` fails a suite whose output has no `Results:` line.
- Skips are counted: `H.skip` stands for one dropped assertion and writes a `SKIP:` line; `Results:` carries passed, failed and skipped, and a suite that asserted nothing fails.
- The floor: `floor_guard_test` mocks `vim.fn.has` and the notifier on a supported Neovim; the real below-floor path is `tests/floor_smoke.sh` on CI's 0.9.5 leg.

## CI

- `.github/workflows/ci.yml`: `test` (Linux and macOS, Neovim stable), `floor` (Neovim 0.10.0) and `floor-below` (Neovim 0.9.5) on the live-server floor; `lint-workflows`, `format` and `commits`; `ci-ok` passes only when each of those passed (`commits` is skipped on a manual run).
- Reporting jobs: `upstream` (live-server `main`) and `windows`; `.github/workflows/nightly.yml` runs Neovim nightly against live-server `main` weekly and by hand. None of them is in `ci-ok`.

## Testing by hand

1. Open a `.md` file, `:MarkdownPreview`; edit and watch the browser update; move the cursor and watch it follow.
2. Takeover: a second Neovim instance previewing another `.md` updates the same tab.
3. Multi: `instance_mode = "multi"` opens one tab per instance.
4. `:MarkdownPreviewStop` stops the server and removes the lock file (takeover primary).
