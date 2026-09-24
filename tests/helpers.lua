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
local errors = {}
local tests_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

-- The repository root is the parent of tests/, whatever the current
-- directory; tests build plugin paths from it.
H.root = vim.fn.fnamemodify(tests_dir, ":p:h:h")

-- A fresh XDG tree per run: stdpath() reads the variables at call time
-- (measured on 0.12.5), so cache, data and state move for everything created
-- after this call. The startup log is opened before any script runs and stays
-- in the state dir Neovim started with; a runner that must isolate it sets
-- XDG_STATE_HOME in the environment. The check turns a Neovim that cached the
-- paths at startup into a loud failure instead of writes into the real tree.
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

-- live-server.nvim, the dependency, is found from $LIVE_SERVER_RTP,
-- ./live-server-rtp (the CI checkout) or ../live-server.nvim (the sibling
-- clone); the first that exists wins. A set override that is not a directory
-- raises, and so does finding none or a directory the search does not resolve
-- to: falling through would let require load whatever live-server the startup
-- runtimepath or packpath carries.
function H.rtp()
    vim.opt.runtimepath:prepend(H.root)
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
    table.insert(candidates, H.root .. "/live-server-rtp")
    table.insert(candidates, H.root .. "/../live-server.nvim")
    for _, dir in ipairs(candidates) do
        if vim.fn.isdirectory(dir) == 1 then
            -- The sibling candidate carries a ".." segment no caller should
            -- see; the name was checked literally, so it is not expanded here.
            dir = vim.fs.normalize(dir, { expand_env = false })
            vim.opt.runtimepath:prepend(dir)
            -- The runtimepath interprets an entry at search time ($VAR, a
            -- comma, a glob), so the string checked above is not the entry
            -- require sees, and an empty directory passes that check; only
            -- the file the search resolves proves the entry (measured).
            local hit = vim.api.nvim_get_runtime_file("lua/live_server/server.lua", false)[1]
            if not (hit and vim.startswith(vim.fs.normalize(hit, { expand_env = false }), dir .. "/")) then
                error("live-server.nvim at " .. dir .. " does not resolve: " .. tostring(hit) .. " (a name with $, a comma or a glob character, or an empty directory)")
            end
            return dir
        end
    end
    error("live-server.nvim not found: set LIVE_SERVER_RTP, or check it out at ./live-server-rtp or ../live-server.nvim")
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
-- answers into a failed assertion instead of a hung suite.
-- status is 0 whenever curl itself reports failure (refused, timed out, a body
-- shorter than its Content-Length: curl exit 18) and curl_exit carries curl's
-- code; a peer that sends a status line and closes is a 200 with an empty body
-- by curl's rules, so a test that needs the body asserts on it. vim.fn.system
-- maps NUL bytes to SOH in the body, so a binary payload is compared by length
-- or through a file, never byte for byte through this helper.
function H.http_get(url, headers)
    local cmd = { "curl", "-q", "-g", "--path-as-is", "--noproxy", "*", "-s", "--max-time", "5", "--connect-timeout", "2", "-o", "-", "-w", "\nHTTPSTATUS:%{http_code}" }
    for _, h in ipairs(headers or {}) do
        table.insert(cmd, "-H")
        table.insert(cmd, h)
    end
    table.insert(cmd, url)
    local out = vim.fn.system(cmd)
    local curl_exit = vim.v.shell_error
    local body, status = out:match("^(.*)\nHTTPSTATUS:(%d+)%s*$")
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

-- An error a callback raised while vim.fn.system blocked waits in the event
-- queue and reaches v:errmsg only when the loop runs again (measured on 0.10.0
-- and 0.12.5), so H.errors and H.expect_error drain the loop before they read
-- it.
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
function H.finish()
    open_ledger("H.finish")
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
        vim.cmd("cq 1")
    end
end

-- A suite that returns early or never calls H.finish() would exit 0 whatever
-- it asserted, and after a passing ruling an error a callback raised on the
-- way out still fails the run. Returns true, with the reason printed, when the
-- run must exit 1. Each message ends in its own newline because cq and
-- os.exit skip the one a normal exit writes, which glued the next line of
-- output (a CI ::endgroup:: marker) onto it (measured).
local function exit_must_fail()
    if not verdict then
        print("suite ended without H.finish()\n")
        return true
    end
    if verdict == "pass" then
        local late = H.errors()
        if #late > 0 then
            print("error reported after H.finish(): " .. headline(late[#late]) .. "\n")
            return true
        end
    end
    return false
end

-- The ruling fails closed: an error raised inside it rules exit 1 as well,
-- where in VimLeavePre it left the exit code at 0 (measured). The message goes
-- through io.stdout with a leading newline, since the last print line has not
-- ended yet.
local function exit_must_fail_closed()
    local ok, must_fail = pcall(exit_must_fail)
    if not ok then
        io.stdout:write("\nexit ruling raised: " .. tostring(must_fail) .. "\n")
        return true
    end
    return must_fail
end

-- cq inside VimLeavePre sets the exit code under -l (measured on 0.10.0 and
-- 0.12.5).
vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("tests_helpers_finish", { clear = true }),
    callback = function()
        if exit_must_fail_closed() then
            vim.cmd("cq 1")
        end
    end,
})

-- os.exit leaves without VimLeavePre, so a suite that called it after a
-- failed assertion exited 0 with no ruling (measured); it takes the same
-- ruling on the way out. From a libuv callback (a fast event) the ruling
-- cannot drain (vim.wait raises E5560) and print is dropped before the exit,
-- so it rules on the verdict alone and writes through io.stdout (measured on
-- 0.10.0 and 0.12.5).
local real_exit = os.exit
os.exit = function(code, ...)
    if vim.in_fast_event() then
        if not verdict then
            io.stdout:write("\nsuite ended without H.finish()\n")
            return real_exit(1, ...)
        end
        return real_exit(code, ...)
    end
    if exit_must_fail_closed() then
        return real_exit(1, ...)
    end
    return real_exit(code, ...)
end

return H
