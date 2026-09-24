-- tests/helpers_test.lua
-- Verify the harness every other suite leans on: the root it resolves, the
-- XDG move, the bounded curl and the exit code a gate reads.
--
-- Run: nvim --headless -u NONE -l tests/helpers_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
local xdg = H.isolate()
H.rtp()

local uv = vim.uv or vim.loop
local ok, eq = H.ok, H.eq

H.section("Section 1: root and isolation")
ok(vim.fn.isdirectory(H.root .. "/tests") == 1, "H.root is the directory that holds tests/")
for _, kind in ipairs({ "cache", "data", "state" }) do
    ok(vim.fn.stdpath(kind):find(xdg, 1, true) == 1, ("stdpath %s sits under the XDG root H.isolate() returned"):format(kind))
end

H.section("Section 2: bounded curl")
-- A port the kernel just handed out and took back: almost always refused; if
-- another listener took the port meanwhile the bounded curl still returns 0 or
-- a real status, and the assertion reads status 0 only.
local probe = uv.new_tcp()
probe:bind("127.0.0.1", 0)
local released_port = probe:getsockname().port
probe:close()
eq(H.http_get(("http://127.0.0.1:%d/"):format(released_port)).status, 0, "a refused connection yields status 0")

-- A listener that completes the handshake and never answers: the bounded
-- curl must give up on its own, and the helper must report that as 0.
local hold = uv.new_tcp()
hold:bind("127.0.0.1", 0)
hold:listen(1, function() end)
local t0 = uv.hrtime()
local stalled = H.http_get(("http://127.0.0.1:%d/"):format(hold:getsockname().port))
eq(stalled.status, 0, "a stalled server yields status 0")
eq(stalled.curl_exit, 28, "curl reports its timeout (exit 28)")
ok((uv.hrtime() - t0) / 1e9 < 8, "the stalled request returned within the bound")
hold:close()

-- A one-shot peer that records the request line and answers with reply byte
-- for byte, so each case controls exactly what curl sees.
local function peer(reply)
    local seen = {}
    local srv = uv.new_tcp()
    srv:bind("127.0.0.1", 0)
    srv:listen(8, function()
        local c = uv.new_tcp()
        srv:accept(c)
        local buf = ""
        c:read_start(function(err, data)
            if err or not data then
                c:close()
                return
            end
            buf = buf .. data
            if not seen.line and buf:find("\r\n\r\n", 1, true) then
                seen.line = buf:match("^[^\r\n]*")
                c:read_stop()
                c:write(reply, function()
                    c:shutdown(function() c:close() end)
                end)
            end
        end)
    end)
    return srv, srv:getsockname().port, seen
end

local srv, port, seen = peer("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc")
local short = H.http_get(("http://127.0.0.1:%d/"):format(port))
eq(short.status, 0, "a body shorter than its Content-Length yields status 0")
eq(short.curl_exit, 18, "curl reports the partial transfer (exit 18)")
srv:close()

-- The proxy points at port 9, so a request that honoured it never reaches the peer.
local saved_proxy = vim.env.http_proxy
vim.env.http_proxy = "http://127.0.0.1:9"
srv, port = peer("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
local direct = H.http_get(("http://127.0.0.1:%d/"):format(port))
vim.env.http_proxy = saved_proxy
eq(direct.status, 204, "http_proxy in the environment does not reroute loopback")
srv:close()

srv, port, seen = peer("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
H.http_get(("http://127.0.0.1:%d/./x"):format(port))
eq(seen.line, "GET /./x HTTP/1.1", "dot segments reach the server as written")
srv:close()

-- vim.fn.system mapped NUL to SOH (measured); the body is compared byte for byte.
srv, port = peer("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nA\0B")
eq(H.http_get(("http://127.0.0.1:%d/"):format(port)).body, "A\0B", "a NUL byte in the body comes back intact")
srv:close()

-- A curl killed by a signal reports code 0 (measured); a curl first on PATH
-- that kills itself stands in for it.
if vim.fn.has("win32") == 1 then
    H.skip("a curl killed by SIGTERM reads curl_exit 143 (no kill -TERM $$ on Windows)")
else
    local fake = H.tmpdir()
    H.write_file(fake .. "/curl", "#!/bin/sh\nkill -TERM $$\n")
    assert(uv.fs_chmod(fake .. "/curl", 493))
    local saved_path = vim.env.PATH
    vim.env.PATH = fake .. ":" .. saved_path
    local killed = H.http_get("http://127.0.0.1:9/")
    vim.env.PATH = saved_path
    eq(killed.curl_exit, 143, "a curl killed by SIGTERM reads curl_exit 143")
    eq(killed.status, 0, "a curl killed by a signal yields status 0")
end

H.section("Section 3: the exit code is the ruling")
-- Each case runs in a child of the same binary, since its cq would end this
-- suite too; progpath keeps the child on the version under test. A parse
-- error exits 1 as well (measured), so a case also names the line (a Lua
-- pattern) only its own path prints, and a child without it reports that
-- instead of its code. The bound turns a child that hangs into a failed case
-- instead of a stalled suite; vim.system reports that timeout as exit 124.
-- opts.env adds to the child's environment, opts.helpers loads another copy
-- of the helper, opts.prelude runs before the helper loads and opts.cwd is
-- the child's working directory.
local helpers_path = vim.fs.joinpath(H.root, "tests", "helpers.lua")
local CHILD_TIMEOUT_MS = 30000
local function child_exit(body, expect, opts)
    opts = opts or {}
    local path = vim.fs.joinpath(H.tmpdir(), "child_test.lua")
    H.write_file(path, ("%slocal H = dofile(%q)\n%s\n"):format(opts.prelude or "", opts.helpers or helpers_path, body))
    local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", path }, { env = opts.env, cwd = opts.cwd, timeout = CHILD_TIMEOUT_MS }):wait()
    if r.code == 124 then
        return ("killed after %d ms"):format(CHILD_TIMEOUT_MS)
    end
    if not ((r.stdout or "") .. (r.stderr or "")):find(expect) then
        return ("exit %d without %q"):format(r.code, expect)
    end
    return r.code
end
eq(child_exit('H.ok(false, "deliberate")\nH.finish()', "FAIL: deliberate"), 1, "a failed assertion exits 1")
-- Through H.ok, so a broken H.eq cannot vouch for itself.
ok(child_exit('H.eq(1, 2, "x")\nH.finish()', "FAIL: x %(got 1, want 2%)") == 1, "a failed H.eq exits 1")
eq(child_exit("H.finish()", "No assertion ran"), 1, "a suite with no assertion exits 1")
eq(child_exit('H.ok(true, "x")\nH.finish()', "Results: 1 passed, 0 failed, 0 skipped"), 0, "one passing assertion exits 0")
eq(child_exit('H.ok(true, "x")\nH.skip("y")\nH.finish()', "Results: 1 passed, 0 failed, 1 skipped"), 0, "a skip is counted and fails nothing")
eq(child_exit('H.skip("y")\nH.finish()', "Results: 0 passed, 0 failed, 1 skipped"), 1, "a suite that only skipped exits 1")
eq(child_exit('H.ok(false, "deliberate")', "suite ended without H%.finish%(%)"), 1, "a failed assertion without H.finish() exits 1")
eq(child_exit('H.ok(true, "x")', "suite ended without H%.finish%(%)"), 1, "a passing suite that never calls H.finish() exits 1")
eq(child_exit('H.ok(true, "x")\nH.finish()\nH.ok(true, "late")', "H%.ok after H%.finish%(%)"), 1, "an assertion after H.finish() exits 1")
eq(child_exit('H.ok(false, "deliberate")\nos.exit(0)', "suite ended without H%.finish%(%)"), 1, "a failed assertion then os.exit(0) exits 1")
eq(child_exit('H.ok(true, "x")\nH.finish()\nos.exit(3)', "Results: 1 passed, 0 failed, 0 skipped"), 3, "os.exit after a passing H.finish() keeps its code")
-- From a timer callback (a fast event) os.exit only schedules the ruling,
-- which drains and rules on the main loop, since a fast event can neither
-- drain nor print and 0.13 refuses os.exit there (E5560). Each body ends in a
-- line that fails the case if the timer never fired.
eq(child_exit([[
H.ok(true, "x")
H.finish()
local uv = vim.uv or vim.loop
uv.new_timer():start(10, 0, function() os.exit(0) end)
vim.wait(1000, function() return false end)
os.exit(5)]], "Results: 1 passed, 0 failed, 0 skipped"), 0, "os.exit(0) from a callback after a passing H.finish() exits 0")
eq(child_exit([[
H.ok(false, "deliberate")
local uv = vim.uv or vim.loop
uv.new_timer():start(10, 0, function() os.exit(0) end)
vim.wait(1000, function() return false end)
H.finish()]], "\nsuite ended without H%.finish%(%)\n"), 1, "os.exit(0) from a callback in an unfinished suite exits 1 with the message on its own line")
-- A quit a callback still holds when the main chunk ends runs during Neovim's
-- teardown, after the ruling, and set the exit code again (measured).
eq(child_exit([[
H.ok(true, "sync ok")
vim.schedule(function()
    H.ok(false, "async result is red")
    vim.cmd("qa!")
end)]], "suite ended without H%.finish%(%)"), 1, "a qa! a pending callback runs after the ruling still exits 1")
eq(child_exit([[
H.ok(false, "deliberate")
vim.schedule(function() vim.cmd("cq 0") end)]], "suite ended without H%.finish%(%)"), 1, "a cq 0 a pending callback runs after the ruling still exits 1")
-- Under textlock (an expr mapping) cq raises E565 instead of ending the run.
eq(child_exit([[
H.ok(false, "deliberate")
vim.keymap.set("n", "x", function() H.finish() return "" end, { expr = true })
vim.api.nvim_feedkeys("x", "x", false)]], "cq refused: [^\n]*E565"), 1, "a failing H.finish() whose cq is refused exits 1")
-- H.finish()'s drain serves a callback chain until it stops, so this quit
-- lands before the ruling prints (measured).
eq(child_exit([[
H.ok(false, "deliberate")
local uv = vim.uv or vim.loop
local deadline = uv.hrtime() + 300e6
local function chain()
    if uv.hrtime() < deadline then
        vim.schedule(chain)
    else
        vim.cmd("qa!")
    end
end
vim.schedule(chain)
H.finish()]], "a quit ran inside H%.finish%(%)'s drain"), 1, "a quit a callback runs inside H.finish()'s drain exits 1 and says so")

-- The exits the helper makes itself skip Neovim's teardown, which removes its
-- tempdir and H.isolate's tree inside it. Each child gets a TMPDIR of its
-- own; Neovim's per-user directory stays even after a clean exit (measured),
-- so only what lies below it counts.
local function leftovers(tmp)
    local found = {}
    for name in vim.fs.dir(tmp, { depth = 2 }) do
        if name:find("/", 1, true) then
            table.insert(found, name)
        end
    end
    return table.concat(found, ", ")
end
local tmp = H.tmpdir()
eq(child_exit('H.isolate()\nH.ok(false, "red")', "suite ended without H%.finish%(%)", { env = { TMPDIR = tmp } }), 1, "an unfinished red suite exits 1")
eq(leftovers(tmp), "", "an unfinished red suite leaves no tempdir behind")
tmp = H.tmpdir()
eq(child_exit([[
H.isolate()
H.ok(false, "deliberate")
vim.keymap.set("n", "x", function() H.finish() return "" end, { expr = true })
vim.api.nvim_feedkeys("x", "x", false)]], "cq refused", { env = { TMPDIR = tmp } }), 1, "a refused cq under isolation exits 1")
eq(leftovers(tmp), "", "a refused cq leaves no tempdir behind")
-- tempname() returns "" when Neovim has no tempdir, and the parent of "" is
-- ".", so a cleanup that derived its target at exit emptied the working
-- directory. A TMPDIR that is a file cannot force it (Neovim falls back to
-- /tmp, measured), so the prelude stands in for a Neovim without one.
local cwd = H.tmpdir()
H.write_file(cwd .. "/sentinel", "keep")
eq(child_exit('H.ok(false, "red")', "suite ended without H%.finish%(%)",
    { prelude = 'vim.fn.tempname = function() return "" end\n', cwd = cwd }), 1, "an unfinished red suite without a tempdir exits 1")
eq(vim.fn.filereadable(cwd .. "/sentinel"), 1, "an exit without a tempdir leaves the working directory alone")

H.section("Section 4: an error raised in a callback fails the suite")
eq(child_exit([[
local uv = vim.uv or vim.loop
uv.new_timer():start(10, 0, function() error("luv boom") end)
vim.wait(200, function() return false end)
H.ok(true, "the assertions pass")
H.finish()]], "FAIL: error reported: [^\n]*luv boom"), 1, "an error in a timer callback exits 1")
eq(child_exit([[
vim.schedule(function() error("sched boom") end)
H.ok(true, "the assertions pass")
H.finish()]], "FAIL: error reported: [^\n]*sched boom"), 1, "an error in a vim.schedule callback exits 1")
-- The read callback raises while the suite waits in H.http_get, the window
-- where every server handler runs.
eq(child_exit([[
local uv = vim.uv or vim.loop
local srv = uv.new_tcp()
srv:bind("127.0.0.1", 0)
srv:listen(8, function()
    local c = uv.new_tcp()
    srv:accept(c)
    c:read_start(function()
        c:read_stop()
        c:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", function() c:close() end)
        error("tcp boom")
    end)
end)
H.eq(H.http_get(("http://127.0.0.1:%d/"):format(srv:getsockname().port)).status, 200, "the response arrived")
H.finish()]], "FAIL: error reported: [^\n]*tcp boom"), 1, "an error in a tcp read callback during H.http_get exits 1")
eq(child_exit([[
H.ok(true, "the assertions pass")
H.finish()
vim.schedule(function() error("late boom") end)]], "error reported after H%.finish%(%): [^\n]*late boom"), 1, "an error raised after a passing H.finish() exits 1")
-- The ruling runs outside the timer, so the late error is seen; the marker
-- goes to stdout, so the case fails if the timer never fired.
eq(child_exit([[
H.ok(true, "x")
H.finish()
vim.schedule(function() error("late") end)
local uv = vim.uv or vim.loop
uv.new_timer():start(50, 0, function()
    io.stdout:write("timer fired\n")
    os.exit(0)
end)
vim.wait(1000, function() return false end)]], "timer fired.*error reported after H%.finish%(%): [^\n]*late"), 1, "a late callback error then os.exit(0) from a callback exits 1")

H.section("Section 5: H.expect_error consumes only the message it expects")
eq(child_exit([[
H.ok(H.expect_error("expected boom", function() vim.notify("expected boom", vim.log.levels.ERROR) end), "the expected error was consumed")
H.finish()]], "Results: 1 passed, 0 failed, 0 skipped"), 0, "an expected error notification is consumed")
eq(child_exit([[
H.expect_error("expected boom", function() error("other boom") end)
H.ok(true, "never reached")
H.finish()]], "E5113[^\n]*other boom"), 1, "an error fn raises is not swallowed")
eq(child_exit([[
H.ok(not H.expect_error("expected boom", function() vim.notify("other boom", vim.log.levels.ERROR) end), "a different message is not consumed")
H.finish()]], "Results: 1 passed, 1 failed"), 1, "a different error message stays for the ledger")
eq(child_exit('H.ok(not H.expect_error("x", function() end), "no error reported gives false")\nH.finish()', "Results: 1 passed, 0 failed, 0 skipped"), 0, "no error reported gives false")
eq(child_exit([[
H.ok(H.expect_error("expected boom", function()
    vim.schedule(function() vim.notify("expected boom", vim.log.levels.ERROR) end)
end), "the expected error was consumed")
H.finish()]], "Results: 1 passed, 0 failed, 0 skipped"), 0, "an expected error reported through a callback is seen")
-- The scheduled error already sits in v:errmsg when fn runs, so without the
-- sample first fn's own message would overwrite it.
eq(child_exit([[
vim.schedule(function() error("sched boom") end)
vim.wait(20, function() return false end)
H.ok(H.expect_error("expected boom", function() vim.notify("expected boom", vim.log.levels.ERROR) end), "the expected error was consumed")
H.finish()]], "FAIL: error reported: [^\n]*sched boom"), 1, "a callback error pending before H.expect_error still fails the suite")

H.section("Section 6: H.rtp proves the checkout is the copy require loads")
-- A comma in the checkout's path splits its runtimepath entry and a copy on
-- the packpath answers instead (measured). markdown-preview runs this file
-- against its own H.rtp, which proves its own entry file first, so both
-- trees carry both plugins' entry files and the message is matched up to lua/.
local base = H.tmpdir()
if base:find("[,$*?%[%]{}]") then
    H.skip("a checkout whose path the runtimepath splits raises (the temp path " .. base .. " carries a comma, a dollar sign or a glob character)")
else
    local root = base .. "/a,b/checkout"
    vim.fn.mkdir(root .. "/tests", "p")
    assert(uv.fs_copyfile(helpers_path, root .. "/tests/helpers.lua"))
    -- The start package goes where the child's packpath looks: stdpath()
    -- reads the variable at call time and follows NVIM_APPNAME (nvim-data on
    -- Windows).
    local data = base .. "/data"
    local saved_data = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = data
    local installed = vim.fn.stdpath("data") .. "/site/pack/x/start/live-server"
    vim.env.XDG_DATA_HOME = saved_data
    for _, dir in ipairs({ root, installed }) do
        for _, rel in ipairs({ "lua/live_server/server.lua", "lua/live_server/util.lua", "lua/markdown_preview/init.lua" }) do
            vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. rel), "p")
            H.write_file(dir .. "/" .. rel, "return {}\n")
        end
    end
    eq(child_exit("H.rtp()", vim.pesc(("the checkout at %s does not resolve: %s/lua/"):format(root, installed)),
        { helpers = root .. "/tests/helpers.lua", env = { XDG_DATA_HOME = data } }), 1,
        "a checkout whose path the runtimepath splits raises, naming the installed copy")
end

H.finish()
