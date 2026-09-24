-- tests/helpers.lua
-- Shared by every headless suite: XDG isolation for everything a suite
-- creates, a bounded curl and one pass/fail ledger whose exit code is the
-- ruling. Loaded by path (dofile), never by require, so nothing under tests/
-- joins the plugin's public module tree.
local uv = vim.uv or vim.loop
local H = {}

local passed, failed, skipped = 0, 0, 0
-- nil until H.finish() rules, then "pass" or "fail".
local verdict
-- Set while H.finish() runs, so a quit its own drain runs is named as such.
local finishing = false
local errors = {}
local tests_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

-- os.exit as Neovim provides it, taken before the wrapper at the end of this
-- file replaces it: a ruling that must end the run calls it directly.
local real_exit = os.exit

-- The repository root is the parent of tests/, whatever the current
-- directory; tests build plugin paths from it.
H.root = vim.fn.fnamemodify(tests_dir, ":p:h:h")

-- A fresh XDG tree per run: stdpath() reads the variables at call time
-- (measured on 0.12.5), so cache, data and state move for everything created
-- after this call. The startup log is opened, and the runtimepath built from
-- the config and data dirs, before any script runs; a runner that must
-- isolate those sets the XDG variables in the environment (tests/run.sh
-- does). The check turns a Neovim that cached the paths at startup into a
-- loud failure instead of writes into the real tree.
function H.isolate()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.env.XDG_CACHE_HOME = root .. "/cache"
    vim.env.XDG_DATA_HOME = root .. "/data"
    vim.env.XDG_STATE_HOME = root .. "/state"
    for _, kind in ipairs({ "cache", "data", "state" }) do
        if vim.fn.stdpath(kind):find(root, 1, true) ~= 1 then
            error(("H.isolate: stdpath('%s') did not follow XDG_%s_HOME: %s"):format(kind, kind:upper(), vim.fn.stdpath(kind)))
        end
    end
    return root
end

-- The runtimepath reads an entry at search time: a comma splits it, a $VAR
-- expands and a glob character matches, so the directory a suite prepends is
-- not always the one require searches, and a copy on the startup packpath
-- answers instead (measured). Only the file the search
-- resolves proves the entry. Returns nil when rel resolves under dir, else
-- what the search found in its place.
local function resolved_elsewhere(dir, rel)
    local hit = vim.api.nvim_get_runtime_file(rel, false)[1]
    local want = vim.fs.normalize(dir .. "/" .. rel, { expand_env = false })
    if hit and vim.fs.normalize(hit, { expand_env = false }) == want then
        return nil
    end
    return tostring(hit)
end

-- The checkout goes first on the runtimepath and proves it is the copy
-- require loads. This file is live-server.nvim's verbatim except here: it
-- proves this plugin's entry file and then finds live-server as a dependency.
-- live-server.nvim is found from $LIVE_SERVER_RTP, ./live-server-rtp (the CI
-- checkout) or the checkout's sibling live-server.nvim (the developer's
-- clone); the first that exists wins and is printed, so a stale
-- ./live-server-rtp shows in every run. A set override that is not a
-- directory raises, and so does finding none or a directory whose modules
-- the search does not resolve to: falling through would let require load
-- whatever live-server the startup runtimepath or packpath carries.
function H.rtp()
    vim.opt.runtimepath:prepend(H.root)
    local elsewhere = resolved_elsewhere(H.root, "lua/markdown_preview/init.lua")
    if elsewhere then
        error(("the checkout at %s does not resolve: %s (a name the runtimepath reads differently: a comma, a dollar sign, a glob character)"):format(H.root, elsewhere))
    end
    -- Built one by one: a nil first element would end ipairs before the
    -- fallbacks, so an unset LIVE_SERVER_RTP would find nothing.
    local candidates = {}
    if vim.env.LIVE_SERVER_RTP and vim.env.LIVE_SERVER_RTP ~= "" then
        local path = vim.env.LIVE_SERVER_RTP
        if vim.fn.isdirectory(path) == 0 then
            error("LIVE_SERVER_RTP is set but is not a directory: " .. path)
        end
        table.insert(candidates, path)
    end
    local ci_checkout = H.root .. "/live-server-rtp"
    -- The physical checkout's sibling: through a symlinked checkout the
    -- kernel resolves ".." from the link's target, where normalize would
    -- resolve it from the link's name.
    local sibling = vim.fs.dirname(uv.fs_realpath(H.root) or H.root) .. "/live-server.nvim"
    table.insert(candidates, ci_checkout)
    table.insert(candidates, sibling)
    for _, dir in ipairs(candidates) do
        if vim.fn.isdirectory(dir) == 1 then
            -- Absolute, so a relative override does not follow a later
            -- directory change; fnamemodify resolves a .. through the
            -- filesystem, as the check above read it (measured), and the
            -- name was checked literally, so it is not expanded here.
            dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"), { expand_env = false })
            vim.opt.runtimepath:prepend(dir)
            -- The plugin requires both modules and server.lua requires util.
            for _, rel in ipairs({ "lua/live_server/server.lua", "lua/live_server/util.lua" }) do
                elsewhere = resolved_elsewhere(dir, rel)
                if elsewhere then
                    error(("live-server.nvim at %s does not resolve: %s (a directory without lua/live_server/server.lua and util.lua, or a name the runtimepath reads differently (a comma, a dollar sign, a glob character))"):format(dir, elsewhere))
                end
            end
            -- The prepend puts dir before the checkout, so a directory that
            -- also carries this plugin's modules answered require instead
            -- while every proof above passed (measured): prove the root again.
            elsewhere = resolved_elsewhere(H.root, "lua/markdown_preview/init.lua")
            if elsewhere then
                error(("the checkout at %s does not resolve: %s (live-server.nvim at %s carries this plugin's modules too)"):format(H.root, elsewhere, dir))
            end
            print("live-server.nvim: " .. dir)
            return dir
        end
    end
    error(("live-server.nvim not found: clone https://github.com/selimacerbas/live-server.nvim (v1.5.0 or newer) to %s or %s, or set LIVE_SERVER_RTP to a checkout"):format(ci_checkout, sibling))
end

function H.tmpdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

function H.write_file(path, data)
    local fd = assert(uv.fs_open(path, "w", 420))
    assert(uv.fs_write(fd, data, 0))
    assert(uv.fs_close(fd))
end

-- Synchronous GET through curl, hermetic and bounded. -q (curl honours it
-- only as the first argument) skips every curlrc, -g stops brace and bracket
-- globbing, --path-as-is sends dot segments as written so the server, not
-- curl, resolves them, and --noproxy keeps a developer's http_proxy off
-- loopback. The bound turns a firewall that swallows SYNs or a peer that never
-- answers into a failed assertion instead of a hung suite; vim.system's
-- timeout is a second bound should curl's own fail (it reports exit 124).
-- status is 0 whenever curl itself reports failure (refused, timed out, a body
-- shorter than its Content-Length: curl exit 18) and curl_exit carries curl's
-- code; a peer that sends a status line and closes is a 200 with an empty body
-- by curl's rules, so a test that needs the body asserts on it. vim.system
-- returns the body byte for byte, where vim.fn.system mapped NUL to SOH, and
-- a SIGINT during its wait ends the suite, where vim.fn.system left a Neovim
-- that ignored INT and TERM (measured on 0.12.5). A curl killed by a signal
-- reports code 0, so curl_exit reads it the shell's way, 128 + the signal;
-- the timeout's own code (124) wins over the signal it sends.
function H.http_get(url, headers)
    local cmd = { "curl", "-q", "-g", "--path-as-is", "--noproxy", "*", "-s", "--max-time", "5", "--connect-timeout", "2", "-o", "-", "-w", "\nHTTPSTATUS:%{http_code}" }
    for _, h in ipairs(headers or {}) do
        table.insert(cmd, "-H")
        table.insert(cmd, h)
    end
    table.insert(cmd, url)
    local result = vim.system(cmd, { text = false, timeout = 8000 }):wait()
    local curl_exit = result.code ~= 0 and result.code or (result.signal ~= 0 and 128 + result.signal or 0)
    local body, status = (result.stdout or ""):match("^(.*)\nHTTPSTATUS:(%d+)%s*$")
    if curl_exit ~= 0 then
        return { status = 0, body = body or "", curl_exit = curl_exit }
    end
    return { status = tonumber(status) or 0, body = body or "", curl_exit = 0 }
end

-- An error raised in a libuv or vim.schedule callback, where every server
-- handler runs, prints a traceback and leaves the exit code at 0; v:errmsg is
-- the one trace of it a script can read, and it holds only the latest
-- message, so every ledger call samples it. The :messages history cannot stand
-- in: every print() enters it and it keeps 500 lines on 0.12.5, 200 on 0.10.0,
-- so a long suite evicts an early error (measured). Any error message fails
-- the suite, an error notification too; a suite that provokes one on purpose
-- goes through H.expect_error, which consumes only the message it expects.
local function sample_errmsg()
    if vim.v.errmsg ~= "" then
        table.insert(errors, vim.v.errmsg)
        vim.v.errmsg = ""
    end
end

-- The first lines of an error message, without the traceback stderr already
-- carries.
local function headline(e)
    return (e:gsub("\nstack traceback:.*", ""):gsub("\n", " "))
end

-- An error a callback raised while the suite blocked (in vim.fn.system, say)
-- waits in the event queue and reaches v:errmsg only when the loop runs again
-- (measured on 0.10.0 and 0.12.5), so H.errors and H.expect_error drain the
-- loop before they read it.
local function drain()
    vim.wait(10, function() return false end)
end

-- Every error message Neovim reported since the helper loaded.
function H.errors()
    drain()
    sample_errmsg()
    return vim.list_extend({}, errors)
end

-- Runs fn, which should report an error message containing pattern (plain
-- text), and consumes that one message. Errors already pending go to the
-- ledger first, and the loop is drained after fn so a message reported through
-- a callback is seen; a message that does not match stays for the ledger.
-- v:errmsg holds one message: when more than one error is reported while fn
-- runs (its own or a callback's), only the last is compared and the others
-- are lost, so fn reports one error and a suite expecting several calls
-- H.expect_error once per error.
function H.expect_error(pattern, fn)
    H.errors()
    fn()
    drain()
    if vim.v.errmsg ~= "" and vim.v.errmsg:find(pattern, 1, true) then
        vim.v.errmsg = ""
        return true
    end
    return false
end

-- An assertion after the ruling would never reach the exit code.
local function open_ledger(caller)
    if verdict then
        error(caller .. " after H.finish(): the ruling is already out", 3)
    end
    sample_errmsg()
end

-- Output written before the process ends without Neovim's own teardown.
local function flush()
    io.stdout:flush()
    io.stderr:flush()
end

-- real_exit skips Neovim's teardown, which removes its per-process tempdir
-- and H.isolate's XDG tree inside it (one left per unfinished red child on
-- 0.10 and 0.12, measured); tempname() creates that dir on demand if absent.
local function cleanup()
    vim.fn.delete(vim.fn.fnamemodify(vim.fn.tempname(), ":h"), "rf")
end

-- Every exit the helper makes itself: output flushed, the tempdir removed.
local function exit_now(code, ...)
    flush()
    cleanup()
    return real_exit(code, ...)
end

-- An exit ruling's reason, through io.stdout with a newline on both sides: on
-- 0.12 a print line ends only when the next begins, and cq and os.exit skip
-- the newline a normal exit writes, which glued the next line of output (a CI
-- ::endgroup:: marker) onto it; print on 0.10.0 ends a line in \r\n and cut
-- a long message short under textlock (measured).
local function say(msg)
    io.stdout:write("\n" .. msg .. "\n")
end

function H.section(title)
    print(((passed + failed + skipped) > 0 and "\n" or "") .. title)
end

function H.ok(cond, msg)
    open_ledger("H.ok")
    if cond then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        failed = failed + 1
        print("  FAIL: " .. msg)
    end
end

function H.eq(a, b, msg)
    open_ledger("H.eq")
    if a == b then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        failed = failed + 1
        print(string.format("  FAIL: %s (got %s, want %s)", msg, tostring(a), tostring(b)))
    end
end

-- A skip drops an assertion, so it is counted and printed, never silent.
function H.skip(msg)
    open_ledger("H.skip")
    skipped = skipped + 1
    print("  SKIP: " .. msg)
end

-- The exit code is the ruling every gate reads; the summary is for the reader.
-- A suite that asserted nothing proved nothing, so it fails as well, and so
-- does one whose callbacks raised. The last banner line carries its own
-- newline because cq skips the one a normal exit writes (measured on 0.12.5).
-- cq ends the run through Neovim's own teardown; where Ex commands are refused
-- (textlock, an expr mapping: E565) it raised and the run went on to exit 0
-- (measured), so a cq that raises or returns falls through to the real exit.
function H.finish()
    open_ledger("H.finish")
    finishing = true
    for _, e in ipairs(H.errors()) do
        failed = failed + 1
        print("  FAIL: error reported: " .. headline(e))
    end
    if passed + failed == 0 then
        print("No assertion ran: a suite that checks nothing is not a pass.")
    end
    print("\n========================================")
    print(string.format("Results: %d passed, %d failed, %d skipped", passed, failed, skipped))
    print("========================================\n")
    verdict = (failed > 0 or passed == 0) and "fail" or "pass"
    if verdict == "fail" then
        local ok, err = pcall(vim.cmd, "cq 1")
        if not ok then
            say("cq refused: " .. headline(tostring(err)))
        end
        exit_now(1)
    end
end

-- A suite that returns early or never calls H.finish() would exit 0 whatever
-- it asserted, and after a passing ruling an error a callback raised on the
-- way out still fails the run. A failing ruling fails the exit too, whichever
-- path ends the process. Returns true, with the reason said, when the run
-- must exit 1.
local function exit_must_fail()
    if verdict == "fail" then
        return true
    end
    if not verdict then
        -- The drain inside H.finish() serves a callback chain until it stops,
        -- so a quit from one ends the run before the ruling prints (measured).
        say(finishing and "a quit ran inside H.finish()'s drain; the suite's own ruling never printed" or "suite ended without H.finish()")
        return true
    end
    local late = H.errors()
    if #late > 0 then
        say("error reported after H.finish(): " .. headline(late[#late]))
        return true
    end
    return false
end

-- Set once a ruling fails the run, so a later exit path neither prints the
-- reason again nor rules it away.
local exit_failed = false

-- The ruling fails closed: an error raised inside it rules exit 1 as well,
-- where in VimLeavePre it left the exit code at 0 (measured).
local function exit_must_fail_closed()
    if exit_failed then
        return true
    end
    local ok, must_fail = pcall(exit_must_fail)
    if not ok then
        say("exit ruling raised: " .. tostring(must_fail))
        must_fail = true
    end
    exit_failed = must_fail
    return must_fail
end

-- cq in VimLeavePre let a quit still pending (a vim.schedule callback running
-- qa! or cq 0 while Neovim tears down) set the exit code after it, so a red
-- suite exited 0 (measured on 0.10.0 and 0.12.5); the ruling ends the process
-- itself unless the exit under way already carries 1. On 0.13 os.exit is
-- Neovim's own exit, which fires this event and runs pending callbacks first,
-- so the autocmd is nested: a quit such a callback runs fires it again and is
-- ruled like any other (measured on nightly v0.13.0-dev).
vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("tests_helpers_finish", { clear = true }),
    nested = true,
    callback = function()
        if exit_must_fail_closed() and vim.v.exiting ~= 1 then
            exit_now(1)
        end
    end,
})

-- os.exit leaves without VimLeavePre on 0.10 and 0.12, so a suite that called
-- it after a failed assertion exited 0 with no ruling (measured); it takes the
-- same ruling on the way out. A fast event (a libuv callback) can neither
-- drain the loop nor print, 0.13 refuses os.exit there (E5560), and an error
-- raised just before it went unseen (measured), so from a fast event the call
-- only schedules the ruling and returns: the run ends at the next turn of the
-- loop with the code the ruling gives, and the caller's code after os.exit
-- runs until then.
local exit_scheduled = false
os.exit = function(code, ...)
    if vim.in_fast_event() then
        if not exit_scheduled then
            exit_scheduled = true
            local close = ...
            vim.schedule(function()
                if exit_must_fail_closed() then
                    return exit_now(1)
                end
                return exit_now(code, close)
            end)
        end
        return
    end
    if exit_must_fail_closed() then
        return exit_now(1, ...)
    end
    return exit_now(code, ...)
end

return H
