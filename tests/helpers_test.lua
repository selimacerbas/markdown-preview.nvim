-- tests/helpers_test.lua
-- Verify the harness every other suite leans on: the root it resolves and
-- the XDG move (Section 1), the bounded curl (2), the exit code a gate reads
-- (3), an error a callback raises failing the suite (4), H.expect_error (5),
-- H.rtp's proof of the copy require loads (6) and one spelling per path (7).
--
-- Run: nvim --headless -u NONE -l tests/helpers_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
local xdg = H.isolate()
local rtp_dir = H.rtp()

local uv = vim.uv
local ok, eq = H.ok, H.eq

H.section("Section 1: root and isolation")
ok(vim.fn.isdirectory(H.root .. "/tests") == 1, "H.root is the directory that holds tests/")
for _, kind in ipairs({ "cache", "data", "state" }) do
	ok(
		vim.fn.stdpath(kind):find(xdg, 1, true) == 1,
		("stdpath %s sits under the XDG root H.isolate() returned"):format(kind)
	)
end

H.section("Section 2: bounded curl")
-- A port the kernel just handed out and took back is refused, and refused is
-- curl 7, where a socket left bound and silent reads 28 with the same status
-- 0; the connect bound sits above Windows's retry of a refused loopback
-- connect so that the Windows job reads 7 here too. A listener that takes
-- the port in the moment between the close and the connect reads red.
local probe = uv.new_tcp()
probe:bind("127.0.0.1", 0)
local released_port = probe:getsockname().port
probe:close()
local refused = H.http_get(("http://127.0.0.1:%d/"):format(released_port))
eq(refused.status, 0, "a refused connection yields status 0")
eq(refused.curl_exit, 7, "curl reports the refused connection (exit 7)")

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
					c:shutdown(function()
						c:close()
					end)
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
	H.skip("a curl killed by a signal yields status 0 (no kill -TERM $$ on Windows)")
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
-- A child killed by a signal reports code 0 (measured), so its exit is read
-- through H.exit_code, 128 + the signal, as the helper reads curl's.
-- opts.env adds to the child's environment, opts.helpers loads another copy
-- of the helper, opts.prelude runs before the helper loads, opts.cwd is the
-- child's working directory and opts.merged joins the child's stderr to its
-- stdout at the descriptor through POSIX sh, as tests/run.sh's 2>&1 does
-- (otherwise stdout is read before stderr); a merged case skips, counted,
-- where no sh is on PATH (the hosted Windows runner has Git's). The first
-- hosted run's log reads as a Windows child ending its lines in \r\n, which
-- a pattern naming \n misses, so the output is read with every line end
-- folded to \n, once, here (the hosted Windows runs since pass with it). A case
-- that fails names the pattern it missed and the child's output, each on
-- one line (vim.inspect escapes the newlines %q would write), so a Results
-- line inside either never starts a line of this suite's own log, where the
-- runner looks for one at column zero. The output and vim.system's result
-- follow the code, for a case that reads further or reads the streams apart.
local helpers_path = vim.fs.joinpath(H.root, "tests", "helpers.lua")
local CHILD_TIMEOUT_MS = 30000
local has_sh = vim.fn.executable("sh") == 1
local function child_exit(body, expect, opts)
	opts = opts or {}
	local path = vim.fs.joinpath(H.tmpdir(), "child_test.lua")
	H.write_file(path, ("%slocal H = dofile(%q)\n%s\n"):format(opts.prelude or "", opts.helpers or helpers_path, body))
	local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l", path }
	if opts.merged then
		cmd = { "sh", "-c", 'exec "$0" "$@" 2>&1', unpack(cmd) }
	end
	local r = vim.system(cmd, { env = opts.env, cwd = opts.cwd, timeout = CHILD_TIMEOUT_MS }):wait()
	local code = H.exit_code(r)
	local out = ((r.stdout or "") .. (r.stderr or "")):gsub("\r+\n", "\n")
	if code == 124 then
		return ("killed after %d ms; the child wrote %s"):format(CHILD_TIMEOUT_MS, vim.inspect(out)), out, r
	end
	if not out:find(expect) then
		return ("exit %d without %s; the child wrote %s"):format(code, vim.inspect(expect), vim.inspect(out)), out, r
	end
	return code, out, r
end
eq(child_exit('H.ok(false, "deliberate")\nH.finish()', "FAIL: deliberate"), 1, "a failed assertion exits 1")
-- Through H.ok, so a broken H.eq cannot vouch for itself.
ok(child_exit('H.eq(1, 2, "x")\nH.finish()', "FAIL: x %(got 1, want 2%)") == 1, "a failed H.eq exits 1")
eq(child_exit("H.finish()", "No assertion ran"), 1, "a suite with no assertion exits 1")
eq(
	child_exit('H.ok(true, "x")\nH.finish()', "Results: 1 passed, 0 failed, 0 skipped"),
	0,
	"one passing assertion exits 0"
)
-- A child that wrote its expected line and then died by a signal must not
-- read as the 0 vim.system reports for it. SIGKILL, since Neovim catches
-- SIGTERM and exits 1 through its own handler (measured on 0.10.0 and
-- 0.12.5).
if vim.fn.has("win32") == 1 then
	H.skip("a child killed by SIGKILL after its expected line reads 137 (no POSIX signal on Windows)")
else
	eq(
		child_exit(
			[[
H.ok(true, "x")
H.finish()
io.stdout:write("written before the kill\n")
io.stdout:flush()
local uv = vim.uv
uv.kill(uv.os_getpid(), "sigkill")]],
			"written before the kill"
		),
		137,
		"a child killed by SIGKILL after its expected line reads 137"
	)
end
eq(
	child_exit('H.ok(true, "x")\nH.skip("y")\nH.finish()', "Results: 1 passed, 0 failed, 1 skipped"),
	0,
	"a skip is counted and fails nothing"
)
eq(
	child_exit('H.skip("y")\nH.finish()', "Results: 0 passed, 0 failed, 1 skipped"),
	1,
	"a suite that only skipped exits 1"
)
eq(
	child_exit('H.ok(false, "deliberate")', "suite ended without H%.finish%(%)"),
	1,
	"a failed assertion without H.finish() exits 1"
)
eq(
	child_exit('H.ok(true, "x")', "suite ended without H%.finish%(%)"),
	1,
	"a passing suite that never calls H.finish() exits 1"
)
eq(
	child_exit('H.ok(true, "x")\nH.finish()\nH.ok(true, "late")', "H%.ok after H%.finish%(%)"),
	1,
	"an assertion after H.finish() exits 1"
)
eq(
	child_exit('H.ok(false, "deliberate")\nos.exit(0)', "suite ended without H%.finish%(%)"),
	1,
	"a failed assertion then os.exit(0) exits 1"
)
eq(
	child_exit('H.ok(true, "x")\nH.finish()\nos.exit(3)', "Results: 1 passed, 0 failed, 0 skipped"),
	3,
	"os.exit after a passing H.finish() keeps its code"
)
-- From a timer callback (a fast event) os.exit only schedules the ruling,
-- which drains and rules on the main loop, since a fast event can neither
-- drain nor print and 0.13 refuses os.exit there (E5560). Each body ends in a
-- line that fails the case if the timer never fired.
eq(
	child_exit(
		[[
H.ok(true, "x")
H.finish()
local uv = vim.uv
uv.new_timer():start(10, 0, function() os.exit(0) end)
vim.wait(1000, function() return false end)
os.exit(5)]],
		"Results: 1 passed, 0 failed, 0 skipped"
	),
	0,
	"os.exit(0) from a callback after a passing H.finish() exits 0"
)
eq(
	child_exit(
		[[
H.ok(false, "deliberate")
local uv = vim.uv
uv.new_timer():start(10, 0, function() os.exit(0) end)
vim.wait(1000, function() return false end)
H.finish()]],
		"\nsuite ended without H%.finish%(%)\n"
	),
	1,
	"os.exit(0) from a callback in an unfinished suite exits 1 with the message on its own line"
)
-- A child that writes \r\n itself pins the fold on every platform; one CR
-- more, as a text-mode stdout on Windows would add, folds the same.
eq(
	child_exit(
		[[
io.stdout:write("\r\nfolded\r\r\n")
H.ok(true, "x")
H.finish()]],
		"\nfolded\n"
	),
	0,
	"a child's \\r\\n line ends read as \\n"
)
-- A line a parent reads back goes through H.write_line: on 0.12.5 a print
-- line that fills a multiple of the message grid's width lost its newline to
-- the next (measured at 80, 160, 240 and 320 columns, and at 10000; never on
-- 0.10.0), so the length of a temp path decided whether two captured lines
-- stayed two. The helper widens the grid, so these lines are built at the
-- width the child runs at (the same helper sets it here): a line of 80 no
-- longer fills it, and a print of one would pass (measured).
local grid = vim.o.columns
eq(
	child_exit(
		('H.write_line(%q)\nH.write_line("second")\nH.ok(true, "x")\nH.finish()'):format(("x"):rep(grid)),
		("x"):rep(grid) .. "\n+second\n"
	),
	0,
	"a line exactly as wide as the message grid and the next one stay two lines"
)
-- The ledger's own lines go the same way: a PASS line exactly as wide as the
-- grid printed on 0.12.5 swallowed the next ledger line (measured), so the
-- width of a message decided which lines a reader or a grep of the log found.
eq(
	child_exit(
		('H.ok(true, %q)\nH.ok(true, "second")\nH.finish()'):format(("w"):rep(grid - 8)),
		"  PASS: " .. ("w"):rep(grid - 8) .. "\n  PASS: second\n.-\nResults: 2 passed, 0 failed, 0 skipped\n"
	),
	0,
	"a PASS line exactly as wide as the message grid leaves the next line and the Results line at column zero"
)
-- A message the suite caused holds its line open on stderr until the next
-- message begins, and the runner merges stderr into stdout, so the next
-- ledger line ends that line first: without it the two shared one line
-- (measured).
-- A headless Neovim is 80 columns wide, and on 0.12.5 a print that fills a
-- multiple of that lost its newline to the ledger line after it (measured
-- at 80 and 160); the helper widens the screen at load. The empty echo
-- writes nothing when no message is open, so two ledger lines in a row take
-- no empty line between them in the merged stream either.
local merged_cases = {
	{
		'print("a message the suite caused")\nH.ok(true, "after the message")\nH.finish()',
		"a message the suite caused\n  PASS: after the message\n",
		"a ledger line after the suite's own message starts a line",
	},
	{
		('print(%q)\nH.ok(true, "after 80")\nprint(%q)\nH.ok(true, "after 160")\nH.finish()'):format(
			("x"):rep(80),
			("y"):rep(160)
		),
		("x"):rep(80) .. "\n  PASS: after 80\n" .. ("y"):rep(160) .. "\n  PASS: after 160\n",
		"a ledger line after an 80-column and after a 160-column print starts a line",
	},
	{
		'H.ok(true, "first")\nH.ok(true, "second")\nH.finish()',
		"  PASS: first\n  PASS: second\n",
		"two ledger lines in a row take no empty line between them",
	},
}
for _, case in ipairs(merged_cases) do
	if has_sh then
		eq(child_exit(case[1], case[2], { merged = true }), 0, case[3])
	else
		H.skip(case[3] .. " (no sh on PATH to merge the streams)")
	end
end
-- The ledger writes to stdout itself, so a suite's own print, which goes to
-- stderr under -l, cannot stand between it and the runner's grep.
local split_code, _, split = child_exit('print("the suite\'s own message")\nH.ok(true, "on stdout")\nH.finish()', "")
local split_out = split and (split.stdout or ""):gsub("\r+\n", "\n") or ""
local split_err = split and (split.stderr or ""):gsub("\r+\n", "\n") or ""
eq(
	("exit %s, stdout %s, stderr %s"):format(
		tostring(split_code),
		tostring(split_out:find("  PASS: on stdout\n", 1, true) ~= nil and not split_out:find("own message", 1, true)),
		tostring(split_err:find("the suite's own message", 1, true) ~= nil and not split_err:find("PASS", 1, true))
	),
	"exit 0, stdout true, stderr true",
	"the ledger line is on stdout and the suite's print on stderr"
)
-- A quit a callback still holds when the main chunk ends runs during Neovim's
-- teardown, after the ruling, and set the exit code again (measured).
eq(
	child_exit(
		[[
H.ok(true, "sync ok")
vim.schedule(function()
    H.ok(false, "async result is red")
    vim.cmd("qa!")
end)]],
		"suite ended without H%.finish%(%)"
	),
	1,
	"a qa! a pending callback runs after the ruling still exits 1"
)
eq(
	child_exit(
		[[
H.ok(false, "deliberate")
vim.schedule(function() vim.cmd("cq 0") end)]],
		"suite ended without H%.finish%(%)"
	),
	1,
	"a cq 0 a pending callback runs after the ruling still exits 1"
)
-- Under textlock (an expr mapping) cq raises E565 instead of ending the run.
eq(
	child_exit(
		[[
H.ok(false, "deliberate")
vim.keymap.set("n", "x", function() H.finish() return "" end, { expr = true })
vim.api.nvim_feedkeys("x", "x", false)]],
		"cq refused: [^\n]*E565"
	),
	1,
	"a failing H.finish() whose cq is refused exits 1"
)
-- H.finish()'s drain serves a callback chain until it stops, so this quit
-- lands before the ruling prints (measured).
eq(
	child_exit(
		[[
H.ok(false, "deliberate")
local uv = vim.uv
local deadline = uv.hrtime() + 300e6
local function chain()
    if uv.hrtime() < deadline then
        vim.schedule(chain)
    else
        vim.cmd("qa!")
    end
end
vim.schedule(chain)
H.finish()]],
		"a quit ran inside H%.finish%(%)'s drain"
	),
	1,
	"a quit a callback runs inside H.finish()'s drain exits 1 and says so"
)

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
eq(
	child_exit('H.isolate()\nH.ok(false, "red")', "suite ended without H%.finish%(%)", { env = { TMPDIR = tmp } }),
	1,
	"an unfinished red suite exits 1"
)
eq(leftovers(tmp), "", "an unfinished red suite leaves no tempdir behind")
tmp = H.tmpdir()
eq(
	child_exit(
		[[
H.isolate()
H.ok(false, "deliberate")
vim.keymap.set("n", "x", function() H.finish() return "" end, { expr = true })
vim.api.nvim_feedkeys("x", "x", false)]],
		"cq refused",
		{ env = { TMPDIR = tmp } }
	),
	1,
	"a refused cq under isolation exits 1"
)
eq(leftovers(tmp), "", "a refused cq leaves no tempdir behind")
-- tempname() returns "" when Neovim has no tempdir, and the parent of "" is
-- ".", so a cleanup that derived its target at exit emptied the working
-- directory. A TMPDIR that is a file cannot force it (Neovim falls back to
-- /tmp, measured), so the prelude stands in for a Neovim without one.
local cwd = H.tmpdir()
H.write_file(cwd .. "/sentinel", "keep")
eq(
	child_exit(
		'H.ok(false, "red")',
		"suite ended without H%.finish%(%)",
		{ prelude = 'vim.fn.tempname = function() return "" end\n', cwd = cwd }
	),
	1,
	"an unfinished red suite without a tempdir exits 1"
)
eq(vim.fn.filereadable(cwd .. "/sentinel"), 1, "an exit without a tempdir leaves the working directory alone")

H.section("Section 4: an error raised in a callback fails the suite")
eq(
	child_exit(
		[[
local uv = vim.uv
uv.new_timer():start(10, 0, function() error("luv boom") end)
vim.wait(200, function() return false end)
H.ok(true, "the assertions pass")
H.finish()]],
		"FAIL: error reported: [^\n]*luv boom"
	),
	1,
	"an error in a timer callback exits 1"
)
eq(
	child_exit(
		[[
vim.schedule(function() error("sched boom") end)
H.ok(true, "the assertions pass")
H.finish()]],
		"FAIL: error reported: [^\n]*sched boom"
	),
	1,
	"an error in a vim.schedule callback exits 1"
)
-- The read callback raises while the suite waits in H.http_get, the window
-- where every server handler runs.
eq(
	child_exit(
		[[
local uv = vim.uv
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
H.finish()]],
		"FAIL: error reported: [^\n]*tcp boom"
	),
	1,
	"an error in a tcp read callback during H.http_get exits 1"
)
eq(
	child_exit(
		[[
H.ok(true, "the assertions pass")
H.finish()
vim.schedule(function() error("late boom") end)]],
		"error reported after H%.finish%(%): [^\n]*late boom"
	),
	1,
	"an error raised after a passing H.finish() exits 1"
)
-- The ruling runs outside the timer, so the late error is seen; the marker
-- goes to stdout, so the case fails if the timer never fired.
eq(
	child_exit(
		[[
H.ok(true, "x")
H.finish()
vim.schedule(function() error("late") end)
local uv = vim.uv
uv.new_timer():start(50, 0, function()
    io.stdout:write("timer fired\n")
    os.exit(0)
end)
vim.wait(1000, function() return false end)]],
		"timer fired.*error reported after H%.finish%(%): [^\n]*late"
	),
	1,
	"a late callback error then os.exit(0) from a callback exits 1"
)

H.section("Section 5: H.expect_error consumes only the message it expects")
eq(
	child_exit(
		[[
H.ok(H.expect_error("expected boom", function() vim.notify("expected boom", vim.log.levels.ERROR) end), "the expected error was consumed")
H.finish()]],
		"Results: 1 passed, 0 failed, 0 skipped"
	),
	0,
	"an expected error notification is consumed"
)
eq(
	child_exit(
		[[
H.expect_error("expected boom", function() error("other boom") end)
H.ok(true, "never reached")
H.finish()]],
		"E5113[^\n]*other boom"
	),
	1,
	"an error fn raises is not swallowed"
)
eq(
	child_exit(
		[[
H.ok(not H.expect_error("expected boom", function() vim.notify("other boom", vim.log.levels.ERROR) end), "a different message is not consumed")
H.finish()]],
		"Results: 1 passed, 1 failed"
	),
	1,
	"a different error message stays for the ledger"
)
eq(
	child_exit(
		'H.ok(not H.expect_error("x", function() end), "no error reported gives false")\nH.finish()',
		"Results: 1 passed, 0 failed, 0 skipped"
	),
	0,
	"no error reported gives false"
)
eq(
	child_exit(
		[[
H.ok(H.expect_error("expected boom", function()
    vim.schedule(function() vim.notify("expected boom", vim.log.levels.ERROR) end)
end), "the expected error was consumed")
H.finish()]],
		"Results: 1 passed, 0 failed, 0 skipped"
	),
	0,
	"an expected error reported through a callback is seen"
)
-- The scheduled error already sits in v:errmsg when fn runs, so without the
-- sample first fn's own message would overwrite it.
eq(
	child_exit(
		[[
vim.schedule(function() error("sched boom") end)
vim.wait(20, function() return false end)
H.ok(H.expect_error("expected boom", function() vim.notify("expected boom", vim.log.levels.ERROR) end), "the expected error was consumed")
H.finish()]],
		"FAIL: error reported: [^\n]*sched boom"
	),
	1,
	"a callback error pending before H.expect_error still fails the suite"
)

H.section("Section 6: H.rtp proves the checkout is the copy require loads")
-- H.rtp returns the directory it proved, canonical, and require's search
-- resolves live-server's server.lua under it: the checkout here,
-- markdown-preview's live-server dependency there.
eq(H.canon(rtp_dir), rtp_dir, "H.rtp returns a canonical path")
ok(vim.fn.isdirectory(rtp_dir) == 1, "H.rtp returns a directory")
local resolved = vim.api.nvim_get_runtime_file("lua/live_server/server.lua", false)[1]
ok(
	resolved ~= nil and vim.startswith(H.canon(resolved), rtp_dir .. "/"),
	"live-server's server.lua resolves under the directory H.rtp returns: " .. tostring(resolved)
)

-- A comma in the checkout's path splits its runtimepath entry and a copy on
-- the packpath answers instead (measured). markdown-preview runs this file
-- against its own H.rtp, which proves its own entry file first, so both
-- trees carry both plugins' entry files and the message is matched up to lua/.
-- The child's H.rtp() sits on its line 2, which a refusal names.
local base = H.tmpdir()
local rtp_cases = {
	"a checkout whose path the runtimepath splits raises at the suite's line, naming the installed copy",
	"a checkout whose path holds a brace group raises the search's own error at the suite's line",
	"a checkout reached through a plain-named link to a path with a comma loads and returns its canonical root",
}
if base:find("[,$*?%[%]{}]") then
	for _, msg in ipairs(rtp_cases) do
		H.skip(msg .. " (the temp path " .. base .. " carries a comma, a dollar sign or a glob character)")
	end
else
	-- A checkout under dir: a copy of the helper and both plugins' modules.
	local function checkout(dir)
		vim.fn.mkdir(dir .. "/tests", "p")
		assert(uv.fs_copyfile(helpers_path, dir .. "/tests/helpers.lua"))
		for _, rel in ipairs({
			"lua/live_server/server.lua",
			"lua/live_server/util.lua",
			"lua/markdown_preview/init.lua",
		}) do
			vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. rel), "p")
			H.write_file(dir .. "/" .. rel, "return {}\n")
		end
	end
	local root = base .. "/a,b/checkout"
	checkout(root)
	-- The start package goes where the child's packpath looks: stdpath()
	-- reads the variable at call time and follows NVIM_APPNAME (nvim-data on
	-- Windows).
	local data = base .. "/data"
	local saved_data = vim.env.XDG_DATA_HOME
	vim.env.XDG_DATA_HOME = data
	local installed = vim.fn.stdpath("data") .. "/site/pack/x/start/live-server"
	vim.env.XDG_DATA_HOME = saved_data
	checkout(installed)
	eq(
		child_exit(
			"H.rtp()",
			"child_test%.lua:2: "
				.. vim.pesc(("the checkout at %s does not resolve: %s/lua/"):format(H.canon(root), H.canon(installed))),
			{ helpers = root .. "/tests/helpers.lua", env = { XDG_DATA_HOME = data } }
		),
		1,
		rtp_cases[1]
	)
	-- A live-server with a plain name for markdown-preview's H.rtp, which
	-- finds it through LIVE_SERVER_RTP once the checkout's own proof passes.
	local plain_ls = base .. "/plain-ls"
	vim.fn.mkdir(plain_ls .. "/lua/live_server", "p")
	H.write_file(plain_ls .. "/lua/live_server/server.lua", "return {}\n")
	H.write_file(plain_ls .. "/lua/live_server/util.lua", "return {}\n")
	-- A brace group with a comma makes building the search path raise E220
	-- here (measured), which the refusal names in place of a raw traceback.
	-- The hosted Windows runner drops the entry instead, a glob that matches
	-- nothing, with no error (measured), so the proof finds no hit and the
	-- refusal names the reason: the same refusal, reached another way. A
	-- runtimepath that reads the brace literally loads the checkout, a
	-- counted skip; any other outcome stays red with the output.
	local braced = base .. "/d{a,b}/checkout"
	checkout(braced)
	local brace_want = "child_test%.lua:2: "
		.. vim.pesc(("the checkout at %s does not resolve: the runtimepath raised "):format(H.canon(braced)))
		.. "[^\n]*E220"
	local brace_dropped = "child_test%.lua:2: "
		.. vim.pesc(("the checkout at %s does not resolve: nil ("):format(H.canon(braced)))
		.. "[^\n]*a brace"
	local brace_code, brace_out = child_exit(
		'H.rtp()\nH.write_line("the checkout loaded")\nH.ok(true, "loaded")\nH.finish()',
		"",
		{ helpers = braced .. "/tests/helpers.lua", env = { LIVE_SERVER_RTP = plain_ls } }
	)
	if brace_out:find("E220", 1, true) then
		eq(
			brace_out:find(brace_want) and brace_code
				or ("exit %s without %s; the child wrote %s"):format(
					brace_code,
					vim.inspect(brace_want),
					vim.inspect(brace_out)
				),
			1,
			rtp_cases[2]
		)
	elseif brace_out:find(brace_dropped) then
		eq(brace_code, 1, rtp_cases[2] .. " (the runtimepath drops the entry here: the proof's refusal, no E220)")
	elseif brace_code == 0 and brace_out:find("the checkout loaded", 1, true) then
		H.skip(rtp_cases[2] .. " (the runtimepath reads the brace literally here: the checkout loaded without E220)")
	else
		eq(
			("exit %s without E220 or the proof's refusal; the child wrote %s"):format(
				brace_code,
				vim.inspect(brace_out)
			),
			1,
			rtp_cases[2]
		)
	end
	-- The runtimepath gets the checkout by the name the helper was loaded
	-- through, so a link without a comma loads where the physical name would
	-- be split, and H.rtp still returns the canonical directory server.lua
	-- resolves under.
	local link = base .. "/plain-checkout"
	local linked, link_err = uv.fs_symlink(root, link, { dir = true })
	if linked and uv.fs_stat(link .. "/tests/helpers.lua") then
		eq(
			child_exit(
				[[
local d = H.rtp()
local f = vim.api.nvim_get_runtime_file("lua/live_server/server.lua", false)[1]
H.ok(H.canon(d) == d, "canonical")
H.ok(f ~= nil and vim.startswith(H.canon(f), d .. "/"), "server.lua under it")
H.finish()]],
				"Results: 2 passed, 0 failed, 0 skipped",
				{
					helpers = link .. "/tests/helpers.lua",
					env = { XDG_DATA_HOME = data, LIVE_SERVER_RTP = plain_ls },
				}
			),
			0,
			rtp_cases[3]
		)
	else
		H.skip(
			rtp_cases[3] .. " (no directory symlink here: " .. tostring(link_err or "the link does not resolve") .. ")"
		)
	end
end

H.section("Section 7: one spelling per path")
-- A tempname() is the raw form a suite starts from: through /var on macOS,
-- an 8.3 name on Windows. The inputs each spell one file a second way.
local p = H.tmpdir()
local canon_p = H.canon(p)
vim.fn.mkdir(p .. "/phys/t", "p")
vim.fn.mkdir(p .. "/phys/only-phys", "p")
vim.fn.mkdir(p .. "/links", "p")
eq(
	canon_p,
	vim.fs.normalize(uv.fs_realpath(p), { expand_env = false }),
	"an existing path is the name the filesystem gives it"
)
eq(H.canon(p .. "/phys/"), canon_p .. "/phys", "a trailing slash names the same directory")
eq(H.canon(p .. "/nope/"), canon_p .. "/nope", "a trailing slash after a missing name leaves none")
eq(
	H.canon(p .. "/nope/deeper"),
	canon_p .. "/nope/deeper",
	"a missing name resolves through its deepest existing ancestor"
)
-- :p keeps a . in a missing tail (measured), so the walk must drop it.
eq(H.canon(p .. "/nope/./deeper"), canon_p .. "/nope/deeper", "a . in a missing tail names no directory")
-- The root is the one existing ancestor that ends in a separator.
eq(H.canon("/nope-canon-xyz/a"), H.canon("/") .. "nope-canon-xyz/a", "a missing name under the root gets one separator")
eq(H.canon("/nope-canon-xyz/../.."), H.canon("/"), "a .. at the root stays at the root")
-- A name under a file is missing (ENOTDIR), not an error: the walk goes on
-- through the file's own name, a .. after it included.
local plain = p .. "/plain"
H.write_file(plain, "")
local function canon_or_raise(path)
	local done, got = pcall(H.canon, path)
	return done and got or ("raised " .. tostring(got))
end
eq(
	canon_or_raise(plain .. "/x") .. " " .. canon_or_raise(plain .. "/x/../y"),
	canon_p .. "/plain/x " .. canon_p .. "/plain/y",
	"a name under a file resolves through the file's name"
)
eq(H.canon("~/nope-canon-xyz"), H.canon(vim.fn.expand("~")) .. "/nope-canon-xyz", "a leading ~ is the home directory")
-- normalize expands $VAR unless told not to, and a $ in a directory's name
-- is a character: a message names the directory that exists
-- (markdown-preview's rtp_test override case). A file system that refuses
-- the name skips both, measured by the mkdir itself, as markdown-preview.nvim's
-- rtp_test does.
local odd_made, odd_err = uv.fs_mkdir(p .. "/odd$HOME-x", 493)
if odd_made then
	eq(H.canon(p .. "/odd$HOME-x"), canon_p .. "/odd$HOME-x", "a $ in an existing name stays a character")
	eq(H.canon(p .. "/gone$HOME-y"), canon_p .. "/gone$HOME-y", "a $ in a missing name stays a character")
else
	for _, msg in ipairs({ "a $ in an existing name stays a character", "a $ in a missing name stays a character" }) do
		H.skip(msg .. " (this file system refuses the name: " .. tostring(odd_err) .. ")")
	end
end
local unstable = {}
for _, name in ipairs({ p, p .. "/phys/../phys", p .. "/nope", p .. "/missing/../phys", p .. "/odd$HOME-x", "." }) do
	if H.canon(H.canon(name)) ~= H.canon(name) then
		table.insert(unstable, name)
	end
end
eq(table.concat(unstable, ", "), "", "a second pass changes nothing")
-- Windows makes a file link unless told dir. A .. after a link resolves from
-- the link's target on POSIX, as the filesystem reads it, also while a name
-- before the link or after the .. is missing, so creating that name does not
-- move the path; Win32 resolves .. by name before the filesystem sees it.
local link = p .. "/links/t"
local linked, link_err = uv.fs_symlink(p .. "/phys/t", link, { dir = true })
local link_cases = {
	"a directory symlink folds to its target",
	"a missing name folded away by .. still resolves the link it lands on",
}
local dotdot_cases = {
	"a .. after a directory symlink resolves from its target",
	"a .. after a directory symlink resolves from its target while a later name is missing",
	"creating the missing name leaves that path where it was",
	"a .. out of a missing name, then a link and a .., reads as the kernel will",
	"creating that missing name leaves the path where it was",
	"the same with a missing name after the link's .. reads as the kernel will",
	"creating the first missing name leaves that path where it was too",
	"a .. out of a missing name, then a link with no .. after it, reads as the kernel will",
	"creating that missing name leaves the path through the link where it was",
}
if linked and uv.fs_stat(link) then
	eq(H.canon(link), canon_p .. "/phys/t", link_cases[1])
	eq(H.canon(p .. "/missing/../links/t"), canon_p .. "/phys/t", link_cases[2])
	if vim.fn.has("win32") == 1 then
		for _, msg in ipairs(dotdot_cases) do
			H.skip(msg .. " (Win32 resolves .. by name)")
		end
	else
		eq(H.canon(link .. "/../only-phys"), canon_p .. "/phys/only-phys", dotdot_cases[1])
		eq(H.canon(link .. "/../later/leaf"), canon_p .. "/phys/later/leaf", dotdot_cases[2])
		vim.fn.mkdir(p .. "/phys/later", "p")
		eq(H.canon(link .. "/../later/leaf"), canon_p .. "/phys/later/leaf", dotdot_cases[3])
		-- Fresh names: phys/later exists by now, and the second shape needs a
		-- name after the link's .. that is still missing.
		local climbs = { "/early/../links/t/../y", "/early/../links/t/../unmade/y", "/early/../links/t/y" }
		local before = { H.canon(p .. climbs[1]), H.canon(p .. climbs[2]), H.canon(p .. climbs[3]) }
		vim.fn.mkdir(p .. "/early", "p")
		local kernel = uv.fs_realpath(p .. "/early/../links/t/..")
		kernel = kernel and vim.fs.normalize(kernel, { expand_env = false }) or "(realpath failed)"
		eq(before[1], kernel .. "/y", dotdot_cases[4])
		eq(H.canon(p .. climbs[1]), kernel .. "/y", dotdot_cases[5])
		eq(before[2], kernel .. "/unmade/y", dotdot_cases[6])
		eq(H.canon(p .. climbs[2]), kernel .. "/unmade/y", dotdot_cases[7])
		local through = uv.fs_realpath(p .. "/early/../links/t")
		through = through and vim.fs.normalize(through, { expand_env = false }) or "(realpath failed)"
		eq(before[3], through .. "/y", dotdot_cases[8])
		eq(H.canon(p .. climbs[3]), through .. "/y", dotdot_cases[9])
	end
else
	local why = " (no directory symlink here: " .. tostring(link_err or "the link does not resolve") .. ")"
	for _, msg in ipairs(vim.list_extend(vim.list_extend({}, link_cases), dotdot_cases)) do
		H.skip(msg .. why)
	end
end
ok(
	(p .. "/phys/") ~= (p .. "/phys") and H.same_path(p .. "/phys/", p .. "/phys"),
	"two strings that name one file are the same path"
)
ok(H.same_path(p, canon_p), "a raw tempname and its canonical form are the same path")
ok(not H.same_path(p .. "/phys", p .. "/links"), "two directories are two paths")
-- A missing name has no on-disk case for realpath to give, so only the fold
-- makes two spellings of it one path, and only where the filesystem folds:
-- the helper's measurement is checked against one taken here, and the
-- answer must hold once one of the names is made (on macOS's APFS it flipped
-- from false to true while the fold followed the platform).
vim.fn.mkdir(p .. "/case/probe", "p")
local folds = uv.fs_stat(p .. "/case/PROBE") ~= nil
eq(H.fs_folds_case, folds, "the helper's case-fold measurement matches this filesystem")
local missing_same = H.same_path(p .. "/nope-case", p .. "/NOPE-CASE")
eq(missing_same, folds, "two cases of a missing name are one path where the filesystem folds")
vim.fn.mkdir(p .. "/nope-case", "p")
eq(
	H.same_path(p .. "/nope-case", p .. "/NOPE-CASE"),
	missing_same,
	"making one of the two names leaves the answer where it was"
)
-- A symlink loop names a file that exists and cannot be resolved, so the
-- helper raises with the errno instead of answering with the spelling.
local loop_a, loop_b = p .. "/links/loop-a", p .. "/links/loop-b"
local looped = uv.fs_symlink(loop_b, loop_a) and uv.fs_symlink(loop_a, loop_b)
if looped then
	local canon_ok, canon_err = pcall(H.canon, loop_a)
	ok(not canon_ok and tostring(canon_err):find("ELOOP", 1, true) ~= nil, "H.canon raises ELOOP on a symlink loop")
	-- Past a missing name, the loop is met by the walk over the tail.
	local climb_ok, climb_err = pcall(H.canon, p .. "/missing/../links/loop-a")
	ok(
		not climb_ok and tostring(climb_err):find("ELOOP", 1, true) ~= nil,
		"H.canon raises ELOOP on a symlink loop reached past a missing name"
	)
	local same_ok, same_err = pcall(H.same_path, p, loop_a)
	ok(
		not same_ok and tostring(same_err):find("ELOOP", 1, true) ~= nil,
		"H.same_path raises ELOOP through H.canon on a symlink loop"
	)
else
	H.skip("H.canon raises ELOOP on a symlink loop (no symlink here)")
	H.skip("H.canon raises ELOOP on a symlink loop reached past a missing name (no symlink here)")
	H.skip("H.same_path raises ELOOP through H.canon on a symlink loop (no symlink here)")
end
-- A value a row quotes, cut to a readable length: a long spelling comes
-- back whole, and a luv error quotes the name it could not resolve.
local function cut(s)
	return #s > 200 and (s:sub(1, 200) .. "...") or s
end
-- The error a raise carries, or what came back instead, cut.
local function raised_errno(path, errno)
	local got = canon_or_raise(path)
	return got:match("^raised (H%.canon: " .. errno .. ")") or cut(got)
end
-- A spelling over PATH_MAX (1024 bytes on macOS, 4096 on Linux) that climbs
-- back to a directory that exists. Whether it resolves is the platform's
-- realpath's answer, not the walk's: macOS's refuses it with ENAMETOOLONG
-- (measured), which the walk up must raise rather than climb to a prefix
-- short enough to resolve; glibc's allocates its own buffer and resolves it
-- (measured on the hosted ubuntu runs), which H.canon
-- must then answer with. The row asks the platform first and pins that
-- answer; any other answer stays red, quoted. The spelling climbs back to
-- phys, so a resolution is pinned to phys's own name as well: H.canon's
-- answer and realpath's, each cut, against it.
local long = p .. "/phys" .. ("/t/.."):rep(1000)
local long_cases = {
	"a spelling over PATH_MAX that this realpath refuses raises ENAMETOOLONG",
	"a spelling over PATH_MAX that this realpath resolves reads as its resolution",
}
local platform_real, platform_err, platform_kind = uv.fs_realpath(long)
if platform_kind == "ENAMETOOLONG" then
	eq(raised_errno(long, "ENAMETOOLONG"), "H.canon: ENAMETOOLONG", long_cases[1])
	H.skip(long_cases[2] .. " (this realpath refuses a spelling over PATH_MAX)")
elseif platform_real then
	local short = vim.fs.normalize(assert(uv.fs_realpath(p .. "/phys")), { expand_env = false })
	eq(
		cut(canon_or_raise(long)) .. " / " .. cut(vim.fs.normalize(platform_real, { expand_env = false })),
		short .. " / " .. short,
		long_cases[2]
	)
	H.skip(long_cases[1] .. " (this realpath resolves a spelling over PATH_MAX)")
else
	eq(("realpath answered %s"):format(cut(tostring(platform_err))), "ENAMETOOLONG or a name", long_cases[1])
	H.skip(long_cases[2] .. " (this realpath neither refused nor resolved it)")
end
-- A refused search names a file that exists and cannot be resolved, in the
-- walk up and past a missing name alike. A process that searches a mode-0
-- directory anyway (root, or a file system without POSIX modes) cannot
-- measure it, which the stat of a name under it tells.
local locked = p .. "/locked"
vim.fn.mkdir(locked .. "/in", "p")
local eacces_cases = {
	"a name under a directory without search permission raises EACCES",
	"a name under it reached past a missing name raises EACCES",
}
uv.fs_chmod(locked, 0)
local searched = uv.fs_stat(locked .. "/in") ~= nil
local under_locked = raised_errno(locked .. "/in", "EACCES")
local past_missing = raised_errno(p .. "/missing/../locked/in", "EACCES")
uv.fs_chmod(locked, 448)
if searched then
	for _, msg in ipairs(eacces_cases) do
		H.skip(msg .. " (this process searches a mode-0 directory: root, or no POSIX modes)")
	end
else
	eq(under_locked, "H.canon: EACCES", eacces_cases[1])
	eq(past_missing, "H.canon: EACCES", eacces_cases[2])
end
-- :p leaves a relative name relative once the working directory is gone
-- (measured), so the walk up ends at "." and H.canon raises, naming the
-- cause, where the spelling would compare as some other file. A platform
-- that keeps a process's working directory from removal cannot measure it.
local gone_case = "a relative name raises once the working directory is gone"
local _, gone_out = child_exit(
	[[
local uv = vim.uv
local removed, why = uv.fs_rmdir(uv.cwd())
if removed then
    local done, got = pcall(H.canon, "x/y")
    H.write_line("canon=" .. (done and ("returned " .. tostring(got)) or tostring(got)))
else
    H.write_line("kept=" .. tostring(why))
end
H.ok(true, "reached")
H.finish()]],
	"",
	{ cwd = H.tmpdir() }
)
local kept = gone_out:match("kept=([^\n]*)")
if kept then
	H.skip(gone_case .. " (the working directory cannot be removed here: " .. kept .. ")")
else
	eq(
		gone_out:match("canon=(H%.canon: x/y has no absolute name: the working directory is gone)")
			or vim.inspect(gone_out),
		"H.canon: x/y has no absolute name: the working directory is gone",
		gone_case
	)
end
-- The raise names the suite's own line: the one inside call, found by the
-- file and the line range debug.getinfo gives for it. what is the pattern
-- the message carries after the line, a refused name unless given.
local function blames_caller(call, what)
	local done, err = pcall(call)
	local where = debug.getinfo(call, "S")
	local src, line = tostring(err):match("^(.-):(%d+): " .. (what or "H%.[%w_]+: a path is a non%-empty string"))
	line = tonumber(line)
	return not done
		and src == where.short_src
		and line ~= nil
		and line >= where.linedefined
		and line <= where.lastlinedefined
end
ok(
	blames_caller(function()
		H.canon(nil)
	end),
	"H.canon refuses nil at the suite's line"
)
ok(
	blames_caller(function()
		H.canon("")
	end),
	"H.canon refuses an empty string at the suite's line"
)
ok(
	blames_caller(function()
		H.same_path(nil, nil)
	end),
	"H.same_path refuses nil at the suite's line"
)
ok(
	blames_caller(function()
		H.same_path(p, "")
	end),
	"H.same_path refuses an empty second name at the suite's line"
)
-- The walk over a missing tail raises at the same level as the walk up.
if looped then
	ok(
		blames_caller(function()
			H.canon(p .. "/missing/../links/loop-a")
		end, "H%.canon: ELOOP"),
		"an ELOOP reached past a missing name names the suite's line"
	)
else
	H.skip("an ELOOP reached past a missing name names the suite's line (no symlink here)")
end
-- H.same_path resolves both names itself, so an errno it meets names the
-- suite's line too, not the helper's.
if looped then
	ok(
		blames_caller(function()
			H.same_path(p, loop_a)
		end, "H%.canon: ELOOP"),
		"an ELOOP met through H.same_path names the suite's line"
	)
else
	H.skip("an ELOOP met through H.same_path names the suite's line (no symlink here)")
end

H.finish()
