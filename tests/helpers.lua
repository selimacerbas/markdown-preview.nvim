-- tests/helpers.lua
-- Shared by every headless suite: XDG isolation for everything a suite
-- creates, one spelling per path, a bounded curl and one pass/fail ledger
-- whose exit code is the ruling. Loaded by path (dofile), never by require,
-- so nothing under tests/ joins the plugin's public module tree.
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

local is_win = vim.fn.has("win32") == 1

-- Whether the filesystem folds case is the volume's property, not the
-- platform's: NTFS and macOS's default APFS fold, the usual Linux
-- filesystems do not. It is measured once, where every fixture a suite
-- builds lives: a fresh directory under Neovim's tempdir, a name made in one
-- case and looked up in the other. It stays nil when Neovim has no tempdir.
do
	local dir = vim.fn.tempname()
	if dir ~= "" and uv.fs_mkdir(dir, 448) then
		if uv.fs_mkdir(dir .. "/probe-case", 448) then
			H.fs_folds_case = uv.fs_stat(dir .. "/PROBE-CASE") ~= nil
		end
		vim.fn.delete(dir, "rf")
	end
end

-- A nil or empty name raises at the suite's line (level 3: past this check
-- and the helper that called it), where :p would read it as a file named
-- v:null or as the working directory and a comparison would pass by accident.
local function require_path(fn, path)
	if type(path) ~= "string" or path == "" then
		error(("%s: a path is a non-empty string, not %s"):format(fn, vim.inspect(path)), 3)
	end
end

-- One spelling per file, so a suite compares names by value and a message
-- prints the name a test builds: absolute (:p, a leading ~ expanded), then
-- the name the filesystem gives (it folds a symlink, /var against
-- /private/var on macOS and an 8.3 short name such as RUNNER~1, which
-- tempname() returns on Windows), with forward slashes, no trailing one and
-- a $ kept literal. realpath needs the path to exist, so a name not yet
-- created resolves through its deepest existing ancestor: it reads the same
-- before and after it is made (a dangling link reads as a missing name, so
-- making its target does move a path through it; where the filesystem folds
-- case, a missing name moves to the case it is made in, which H.same_path
-- folds away), and a second pass changes nothing. Only a name that is not
-- there (ENOENT) or sits under a file (ENOTDIR) walks up: any other realpath
-- error (a symlink loop, a refused search) names a file that exists and
-- cannot be resolved, so it raises rather than compare as some other file.
-- The walk runs on the :p form before any fold by name, so a .. after a
-- symlinked directory resolves through the filesystem as the kernel reads
-- it, also while a later name is missing; a .. or . left in the missing tail
-- folds by name, and the result is resolved once more in case the fold
-- landed on a link. The one shape that still moves once made is a missing
-- name followed by a link and a .. (missing/../link/../x): the fold by name
-- crosses the link before it exists to the filesystem walk. No suite builds
-- one; resolving the tail one component at a time would close it.
function H.canon(path)
	require_path("H.canon", path)
	local full = vim.fn.fnamemodify(path, ":p")
	if is_win then
		full = full:gsub("\\", "/")
	end
	local head, tail, folded = full, {}, false
	while true do
		local real, err, kind = uv.fs_realpath(head)
		if not real and kind ~= "ENOENT" and kind ~= "ENOTDIR" then
			error("H.canon: " .. tostring(err), 2)
		end
		if real then
			if #tail == 0 then
				return vim.fs.normalize(real, { expand_env = false })
			end
			-- realpath ends in a separator only at a root, which must not
			-- double into a UNC-looking //.
			local sep = (real:sub(-1) == "/" or (is_win and real:sub(-1) == "\\")) and "" or "/"
			local joined = vim.fs.normalize(real .. sep .. table.concat(tail, "/"), { expand_env = false })
			if folded then
				return H.canon(joined)
			end
			return joined
		end
		local parent = vim.fs.dirname(head)
		if parent == head then
			return vim.fs.normalize(full, { expand_env = false })
		end
		local name = vim.fs.basename(head)
		if name ~= "" then
			table.insert(tail, 1, name)
			folded = folded or name == "." or name == ".."
		end
		head = parent
	end
end

-- Whether two names denote one file. A missing name has no on-disk case for
-- realpath to give, so the comparison folds case where the filesystem does
-- (H.fs_folds_case), and refuses to answer where that was not measured.
function H.same_path(a, b)
	require_path("H.same_path", a)
	require_path("H.same_path", b)
	if H.fs_folds_case == nil then
		error("H.same_path: the filesystem's case fold was not measured (Neovim has no tempdir)", 2)
	end
	a, b = H.canon(a), H.canon(b)
	if H.fs_folds_case then
		return a:lower() == b:lower()
	end
	return a == b
end

-- The repository root is the parent of tests/, whatever the current
-- directory. H.root is canonical, and tests build plugin paths and compare
-- names from it; root_entry names the same directory the way the helper was
-- loaded, which is what the runtimepath gets: a plain-named link to a
-- directory whose real name carries a comma or a $ loads through its own
-- name, where the physical one would be split or expanded.
local root_entry = vim.fs.normalize(vim.fn.fnamemodify(tests_dir, ":p:h:h"), { expand_env = false })
H.root = H.canon(root_entry)

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
			error(
				("H.isolate: stdpath('%s') did not follow XDG_%s_HOME: %s"):format(
					kind,
					kind:upper(),
					vim.fn.stdpath(kind)
				)
			)
		end
	end
	return root
end

-- The two files a module can be, in the order Neovim's loader tries them.
local function module_forms(modname)
	local rel = modname:gsub("%.", "/")
	return { "/lua/" .. rel .. ".lua", "/lua/" .. rel .. "/init.lua" }
end

-- The file require would load for modname, found the way the loader finds
-- it: runtimepath entries in order, and in each lua/<mod>.lua before
-- lua/<mod>/init.lua, so a flat file in an earlier entry wins (measured).
-- The entries are the search path Neovim built, after it split, expanded
-- and globbed the option (with backslashes on Windows), so the file comes
-- back canonical. Building that list can itself raise (a brace group with a
-- comma: E220, measured), so the error comes back as the second value for
-- the proof to name.
local function first_hit(modname)
	local listed, entries = pcall(vim.api.nvim_list_runtime_paths)
	if not listed then
		return nil, "the runtimepath raised " .. tostring(entries)
	end
	for _, entry in ipairs(entries) do
		for _, form in ipairs(module_forms(modname)) do
			if uv.fs_stat(entry .. form) then
				return H.canon(entry .. form)
			end
		end
	end
end

-- The runtimepath reads an entry at search time: a comma splits it, a $VAR
-- expands, a glob character matches, a backslash escapes, a brace group
-- expands and a last component named after makes an after-directory, and an
-- earlier entry answers first, so the directory a suite prepends is not
-- always the one require loads from and a copy on the startup packpath
-- answers instead (measured). Returns nil when modname resolves to root's
-- own file, else the refusal naming what require would load (or what the
-- search raised), which H.rtp raises at the suite's line. Every caller passes
-- a canonical root (H.root, or the directory H.rtp made canonical), so the
-- refusal names it as given.
local function unproven(root, modname, label, reason)
	local own
	for _, form in ipairs(module_forms(modname)) do
		if uv.fs_stat(root .. form) then
			own = root .. form
			break
		end
	end
	local hit, raised = first_hit(modname)
	if own and hit and H.same_path(hit, own) then
		return nil
	end
	return ("%s at %s does not resolve: %s (%s)"):format(label, root, raised or tostring(hit), reason)
end

-- The reason a refusal gives when the directory holds the module and the
-- search still answers elsewhere.
local RTP_SYNTAX =
	"a name the runtimepath reads differently (a comma, a dollar sign, a glob character, a backslash, a brace, or a name ending in after)"

-- The live-server floor this plugin's release notes promise, written once:
-- the not-found message and the suites read it here, and CI's floor step
-- checks this line against the workflow's LIVE_SERVER_FLOOR.
H.live_server_floor = "v1.5.0"

-- The checkout goes first on the runtimepath, by the name the helper was
-- loaded through, and proves it is the copy require loads.
-- live-server.nvim's copy of this file is one source with this one outside
-- H.rtp, indentation aside: here H.rtp proves this plugin's modules and then
-- finds live-server as a dependency. live-server.nvim is found from
-- $LIVE_SERVER_RTP, ./live-server-rtp (the CI checkout) or the checkout's
-- sibling live-server.nvim (the developer's clone); the first that exists
-- wins, goes on the runtimepath by the name it was found under, and is
-- printed and returned canonical, so a stale ./live-server-rtp shows in
-- every run and a test compares the name by value. A set override that is
-- not a directory raises, and so does finding none or a directory whose
-- modules the search does not resolve to: falling through would let require
-- load whatever live-server the startup runtimepath or packpath carries.
-- Every raise names the suite's H.rtp() line.
function H.rtp()
	vim.opt.runtimepath:prepend(root_entry)
	-- Every module the checkout ships, since a copy elsewhere can shadow any
	-- one of them; vim.fs.dir does not glob, where glob() would read a glob
	-- character in H.root (it does expand an environment variable in the
	-- path, and the runtimepath expands it the same way, so that root fails
	-- the proof below either way).
	local modules = { "markdown_preview" }
	for name, kind in vim.fs.dir(H.root .. "/lua/markdown_preview") do
		local base = name:match("^(.+)%.lua$")
		if kind == "file" and base and base ~= "init" then
			table.insert(modules, "markdown_preview." .. base)
		end
	end
	-- The first refusal among this plugin's modules, or nil.
	local function root_refusal(reason)
		for _, modname in ipairs(modules) do
			local refusal = unproven(H.root, modname, "the checkout", reason)
			if refusal then
				return refusal
			end
		end
	end
	local refusal = root_refusal(RTP_SYNTAX)
	if refusal then
		error(refusal, 2)
	end
	-- Built one by one: a nil first element would end ipairs before the
	-- fallbacks, so an unset LIVE_SERVER_RTP would find nothing.
	local candidates = {}
	if vim.env.LIVE_SERVER_RTP and vim.env.LIVE_SERVER_RTP ~= "" then
		local path = vim.env.LIVE_SERVER_RTP
		if vim.fn.isdirectory(path) == 0 then
			-- The value as set: it names the variable, not a path this run
			-- resolved.
			error("LIVE_SERVER_RTP is set but is not a directory: " .. path, 2)
		end
		table.insert(candidates, path)
	end
	local ci_checkout = H.root .. "/live-server-rtp"
	-- H.root is physical, so through a symlinked checkout its parent is the
	-- link target's, the one the kernel resolves ".." to, where the link's
	-- own parent is the one normalize would give.
	local sibling = vim.fs.dirname(H.root) .. "/live-server.nvim"
	table.insert(candidates, ci_checkout)
	table.insert(candidates, sibling)
	for _, found in ipairs(candidates) do
		if vim.fn.isdirectory(found) == 1 then
			-- The entry is the name found, absolute so a relative override
			-- does not follow a later directory change, and a $ in it kept
			-- literal as the directory check read it: a plain-named link to
			-- a directory whose real name carries a comma loads. The name
			-- every proof, print and return uses is canonical, so a ..
			-- resolves through the filesystem (measured).
			local entry = vim.fs.normalize(vim.fn.fnamemodify(found, ":p"), { expand_env = false })
			local dir = H.canon(found)
			vim.opt.runtimepath:prepend(entry)
			-- The plugin requires both modules and server.lua requires util.
			for _, modname in ipairs({ "live_server.server", "live_server.util" }) do
				refusal = unproven(
					dir,
					modname,
					"live-server.nvim",
					"a directory without lua/live_server/server.lua and util.lua, or " .. RTP_SYNTAX
				)
				if refusal then
					error(refusal, 2)
				end
			end
			-- The prepend puts the entry before the checkout, so a directory
			-- that also carries this plugin's modules, in either file form,
			-- answered require instead while every proof above passed
			-- (measured): prove the root again.
			refusal = root_refusal(("live-server.nvim at %s carries this plugin's modules too"):format(dir))
			if refusal then
				error(refusal, 2)
			end
			print("live-server.nvim: " .. dir)
			return dir
		end
	end
	error(
		("live-server.nvim not found: clone https://github.com/selimacerbas/live-server.nvim (%s or newer) to %s or %s, or set LIVE_SERVER_RTP to a checkout"):format(
			H.live_server_floor,
			ci_checkout,
			sibling
		),
		2
	)
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

-- A finished vim.system process's exit read the shell's way: a process killed
-- by a signal reports code 0 with the signal set (measured), which would read
-- as a clean exit, so it is 128 + the signal; a nonzero code wins, so
-- vim.system's own timeout stays 124.
function H.exit_code(result)
	return result.code ~= 0 and result.code or (result.signal ~= 0 and 128 + result.signal or 0)
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
-- that ignored INT and TERM (measured on 0.12.5). curl_exit is curl's exit
-- as H.exit_code reads it, so a curl killed by a signal is 128 + the signal
-- and the timeout's own code (124) wins over the signal it sends. The first
-- hosted Windows run read a refused port as a timeout (curl 28) under a
-- connect bound of 2, which fits Windows retrying a refused loopback connect
-- for about two seconds before it reports it; the bound now sits above that
-- window and below --max-time, so refused should read curl 7 there too (the
-- next Windows run is the measurement).
function H.http_get(url, headers)
	local cmd = {
		"curl",
		"-q",
		"-g",
		"--path-as-is",
		"--noproxy",
		"*",
		"-s",
		"--max-time",
		"5",
		"--connect-timeout",
		"4",
		"-o",
		"-",
		"-w",
		"\nHTTPSTATUS:%{http_code}",
	}
	for _, h in ipairs(headers or {}) do
		table.insert(cmd, "-H")
		table.insert(cmd, h)
	end
	table.insert(cmd, url)
	local result = vim.system(cmd, { text = false, timeout = 8000 }):wait()
	local curl_exit = H.exit_code(result)
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
	vim.wait(10, function()
		return false
	end)
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
-- 0.10 and 0.12, measured). The dir is resolved once, at load, and kept only
-- when absolute and present: tempname() returns "" when Neovim has no
-- tempdir, and the parent of "" is ".", which delete(.., "rf") would empty.
local tempdir
do
	local name = vim.fn.tempname()
	local dir = name ~= "" and vim.fn.fnamemodify(name, ":h") or ""
	local absolute = dir:sub(1, 1) == "/" or dir:match("^%a:[/\\]") ~= nil
	if absolute and vim.fn.isdirectory(dir) == 1 then
		tempdir = dir
	end
end
local function cleanup()
	if tempdir then
		vim.fn.delete(tempdir, "rf")
	end
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
		say(
			finishing and "a quit ran inside H.finish()'s drain; the suite's own ruling never printed"
				or "suite ended without H.finish()"
		)
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
