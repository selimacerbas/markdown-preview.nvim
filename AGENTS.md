# markdown-preview.nvim: agent operating file

Neovim plugin for live markdown preview in the browser. Pure Lua, no npm: the plugin is Lua alone, and its browser test is a bun package under `tests/browser/`. This file is the index for any coding agent and the source of truth for how to work here; CLAUDE.md includes it. The README is the user's contract and CHANGELOG.md the record of what shipped.

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
- `tests/browser/`: the browser smoke test (`smoke.test.ts`), a bun package that pins Playwright exactly (`package.json`, `bun.lock`)
- `.githooks/commit-msg`: the hook `make hooks` copies into the clone with a copy of `.githooks/message-policy`, the one message policy the CI `commits` job runs too; the hook runs that copy, never the working tree's (a merge runs the hook with the merged tree checked out), so `make hooks` runs again after a policy change; `tests/message_policy_test.sh` measures both

## Sibling dependency

- live-server.nvim (`selimacerbas/live-server.nvim`, cloned beside this repo as `../live-server.nvim`) is the pure Lua HTTP server with SSE this plugin drives; one maintainer edits both, and commits stay per repo.
- The live-server floor is v1.5.0 in three places that move together: `H.live_server_floor` in `tests/helpers.lua`, and `LIVE_SERVER_FLOOR` and `LIVE_SERVER_FLOOR_SHA` in `.github/workflows/ci.yml`; the `live-server floor is the pinned tag` step of the local action `.github/actions/live-server-floor`, which the five jobs on the floor share, reds when they disagree, and the gating test jobs run on that commit.
- live-server exports `require("live_server.server").features` (`token_auth`, `host_binding`, `asset_route`); the plugin reads `asset_route` and warns once when it is missing.
- APIs used: `server.start(cfg)` (an instance with `.port`), `server.stop(inst)`, `server.reload(inst, path)`, `server.send_event(inst, event, data)`, `server.update_target(inst, root, index)`, `server.connected_client_count(inst)`, `server.features`, and `util.random_token(16)` from `live_server.util` (the session token).
- Endpoints used: `GET /__live/inject?event=<type>&data=<json>&t=<token>` (remote.lua), and `GET /__live/events?t=<token>` (the event stream) and `GET /__live/asset?p=<relpath>&t=<token>` (the preview page).

## Architecture

- Neovim writes the buffer to `content.md` in a workspace directory under `stdpath("cache")/markdown-preview/` (takeover always; multi unless `workspace_dir` is set); live-server serves it and pushes SSE events (`reload` on change, `scroll` with the cursor line).
- The browser renders with markdown-it, highlight.js, KaTeX and mermaid (loaded from CDNs) and diffs the DOM with morphdom.
- Auth: a per-session token gates five surfaces, `content.md`, the `asset_root` sidecar, the SSE stream, the inject endpoint and the asset route; on the loopback default the index page is not gated and carries the token (`data-live-token`), and on a non-loopback `host` the index page is gated too and carries no token, which the browser takes from the `?t=` URL.
- Instance modes: `takeover` (the default; one shared workspace, port 8421 under the default `port = 0`, a lock file elects the primary) and `multi` (a per-buffer workspace, or `workspace_dir` when set, and a server per instance on an OS-assigned port under the default `port = 0`).
- `mermaid_renderer = "rust"` pre-renders mermaid fences through the `mmdr` CLI; the default renders them in the browser.

## Conventions

- Neovim 0.10 or newer: `lua/markdown_preview/floor.lua` states the requirement and the message once, below it the plugin file and the module stop with that message, and CI proves the refusal on a real Neovim 0.9.5 with `tests/floor_smoke.sh`.
- `vim.uv` for async I/O; Lua patterns, never regex quantifiers.
- StyLua 2.5.2 with `.stylua.toml` (tabs, 120 columns); the Makefile pins the version; bun runs the formatter and the browser test.
- Gates by make target: `make fmt` (writes), `make fmt-check`, `make lint-text` (the em dash), `make lint-blame` (`.git-blame-ignore-revs`), `make shellcheck` (the POSIX scripts and hooks, read as sh), `make test`, `make test-browser` (the browser smoke test, kept out of `make test`); `make hooks` installs the commit-msg hook; `make help` lists them.
- CI runs the same targets: `make fmt-check`, `make lint-text` and `make lint-blame` as written, `make shellcheck` in `lint-workflows` with the pinned actionlint image's shellcheck, `tests/run.sh`, which `make test` runs, in the test, floor, upstream, windows and nightly jobs, and `tests/message_policy_test.sh`, which `make test` runs next, on the test job's Linux leg; the `browser` job runs `make test-browser`, which reads the JUnit report's counts.
- No default keymaps (issue #4). No em dash character anywhere.
- Commits: an imperative subject of at most 72 characters and a body wrapped at 72 columns that says why (prose rules, no gate checks them), and no attribution trailer, no em dash, no workflow skip instruction (CONTRIBUTING.md lists each); `make hooks` installs the hook that refuses those three, never `core.hooksPath`.
- Release titles are clean version numbers (`v1.10.0`); the notes come from the version's section of `CHANGELOG.md`.

## Tests

- `make test` runs `tests/run.sh` (every `tests/*_test.lua` under private XDG directories, then the help tags when `doc/` exists) and then `tests/message_policy_test.sh` (the policy script and the hook, committing in a scratch repository), and fails when either does.
- One suite alone: `nvim --headless -u NONE -l "$PWD/tests/<file>_test.lua"` (the absolute name `tests/run.sh` passes, which keeps a link the checkout is reached through).
- `helpers_test`: the harness itself (root and isolation, the bounded curl, exit rulings, callback errors, `H.expect_error`, `H.rtp`, path spelling).
- `parse_test`: every tracked Lua file parses under this Neovim's LuaJIT (it needs a git checkout), and `lazy.lua` returns exactly one spec, `{ "selimacerbas/live-server.nvim" }`.
- `rtp_test`: how `H.rtp()` proves the checkout and chooses live-server.nvim, and what it refuses.
- `token_auth_test`: the token reaches the served page and gates `content.md`, and the lock file that holds it is private.
- `asset_route_test`: the installed live-server exports `asset_route`, the route serves files beside the document, and the sidecar is gated.
- `floor_guard_test`: below 0.10 every documented command refuses with the floor message; at the floor the commands are defined.
- `tests/floor_smoke.sh`: the refusal on a real Neovim below the floor; CI runs it on 0.9.5, and locally such a Neovim goes first on PATH.
- curl is needed by the three suites that make HTTP requests (`helpers_test`, `token_auth_test`, `asset_route_test`).
- `tests/browser/smoke.test.ts` (`make test-browser`): a headless Neovim serves a buffer, Playwright's headless Chromium renders the page, and an edit over RPC reaches it through the plugin's autocmds and its SSE push, no explicit refresh. It needs bun 1.4.0 or newer (the lockfile's version), Playwright's Chromium (`cd tests/browser && bun install --frozen-lockfile && bun x playwright install --only-shell chromium`, the install first so `bun x` runs the pinned Playwright) and network for the page's CDN libraries (jsDelivr and unpkg); a red browser job after a third-party release, with no change here, is re-run once, and if it stays red the diagnosis names the URL; a red run prints Neovim's output and exit, the page's errors and console warnings, pending and failed requests, 4xx and 5xx responses and the page state.

## Test harness contract

- Shared files: `tests/parity.sh` lists every file this repository shares with live-server.nvim (the harness, the runner, the smoke, the hooks, the Makefile, the PR template) and how it is compared; `make parity SIBLING=../live-server.nvim` runs it and the `upstream` job reports it against live-server `main`. live-server's copy is the source, so a change lands there first. A Lua file compares by `diff -w` (tabs here, 4 spaces there) outside its `-- parity: own lines` markers: here `H.live_server_floor` and `H.rtp` in `tests/helpers.lua`, and the lazy.lua section of `tests/parse_test.lua`.
- Isolation: `tests/run.sh` points the four XDG directories at a private `mktemp -d` before Neovim starts, whatever the caller exported (the hosted ubuntu image exports `XDG_CONFIG_HOME`), and `H.isolate()` moves cache, data and state again before the suite loads the plugin, failing loud when `stdpath()` does not follow.
- Lookup: `H.rtp()` takes `$LIVE_SERVER_RTP`, then `./live-server-rtp` (the CI checkout), then `../live-server.nvim`; a set `LIVE_SERVER_RTP` (empty reads as unset) that is not a directory raises instead of falling through, otherwise the first that exists wins, and finding none raises. `tests/browser/smoke.test.ts` makes the same lookup (a relative `LIVE_SERVER_RTP` resolved against the repository root, the name found put on the runtimepath as it is), prints the chosen path, gives Neovim four XDG directories of its own, and proves over RPC, after the load, that `markdown_preview` and `live_server.server` loaded from the chosen roots, where `H.rtp()` proves every module before any loads.
- Proof: every module of this plugin, and live-server's `server` and `util` (the modules the plugin loads, as the pinned floor ships them), must resolve from the chosen entries, or the suite raises instead of loading an installed copy.
- One canonical path form: `H.canon` gives a path one spelling (absolute, links resolved, forward slashes), and `H.same_path` compares two, folding case where `H.fs_folds_case` measured that the filesystem folds it.
- Exit rulings: the exit code is the ruling; a red suite, one that ends without `H.finish()`, and one whose callback raised exit 1, whatever the suite's own quits, `os.exit` calls and callbacks do.
- Every ledger line is written as a line by `H.write_line` (straight to stdout, its own newline), and `tests/run.sh` fails a suite whose output has no `Results:` line.
- Skips are counted: `H.skip` stands for one dropped assertion and writes a `SKIP:` line; `Results:` carries passed, failed and skipped, and a suite that asserted nothing fails.
- The floor: `floor_guard_test` mocks `vim.fn.has` and the notifier on a supported Neovim; the real below-floor path is `tests/floor_smoke.sh` on CI's 0.9.5 leg.

## CI

- `.github/workflows/ci.yml`: `test` (Linux and macOS, Neovim stable), `floor` (Neovim 0.10.0), `floor-below` (Neovim 0.9.5) and `windows` (Neovim stable) on the live-server floor; `lint-workflows`, `format`, `commits` and `browser` (Linux, Neovim stable, Playwright's headless Chromium, the live-server floor); `ci-ok` passes only when each of those passed; `commits` runs on every event, and a manual run judges the commit it runs on alone.
- Reporting jobs: `upstream` (live-server `main`); `.github/workflows/nightly.yml` runs Neovim nightly against live-server `main` weekly and by hand. Neither is in `ci-ok`.
- Checks only GitHub makes, none of them a make target: actionlint and the composite-action step check in `lint-workflows`; `sha_pinning_required` on the repository's Actions settings (every action pinned by SHA); the pull request title at most 65 characters and the title and body judged by the message policy (`commits`); branch protection on `main` requiring `ci-ok` (strict: the branch up to date), whose context is the job id, so renaming the job or giving it a `name:` leaves every pull request waiting; one approving review, which the maintainer's own pull requests pass through the administrator bypass, with stale approvals kept after a push; squash merges only, the commit taking `PR_TITLE` and `PR_BODY`; and the `release tags` rulesets of this repository and live-server.nvim, which refuse a moved or deleted `v*` tag.

## Testing by hand

1. Open a `.md` file, `:MarkdownPreview`; edit and watch the browser update; move the cursor and watch it follow.
2. Takeover: a second Neovim instance previewing another `.md` updates the same tab.
3. Multi: `instance_mode = "multi"` opens one tab per instance.
4. `:MarkdownPreviewStop` stops the server and removes the lock file (takeover primary).
