-- tests/rtp_test.lua
-- Pin how H.rtp() finds live-server.nvim: an override that is not a directory
-- and a missing dependency raise instead of letting require fall through to
-- an installed copy, and the path it returns is normalized, never env-expanded.
--
-- Run: nvim --headless -u NONE -l tests/rtp_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
-- No H.rtp() here: every case runs it in a child, and a raise in this process
-- would end the suite before the cases that pin it.

local uv = vim.uv or vim.loop
local ok, eq = H.ok, H.eq

-- One child of the same binary per case, since a raise ends the process that
-- runs it. Every child gets LIVE_SERVER_RTP (empty reads as unset), so a value
-- in the caller's environment never leaks into a case; vim.system reports a
-- child killed at the bound as exit 124.
local helpers_path = vim.fs.joinpath(H.root, "tests", "helpers.lua")
local CHILD_TIMEOUT_MS = 30000
local function child(helpers, body, override)
	local path = vim.fs.joinpath(H.tmpdir(), "child_test.lua")
	H.write_file(path, ("local H = dofile(%q)\n%s\n"):format(helpers, body))
	local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", path }, {
		env = { LIVE_SERVER_RTP = override },
		timeout = CHILD_TIMEOUT_MS,
	}):wait()
	return r.code, (r.stdout or "") .. (r.stderr or "")
end

-- The child's exit code when its output carries text, else what went wrong.
local function ruling(code, out, text)
	if code == 124 then
		return ("killed after %d ms"):format(CHILD_TIMEOUT_MS)
	end
	if not out:find(text, 1, true) then
		return ("exit %d without %q"):format(code, text)
	end
	return code
end

H.section("Section 1: a bad override and a missing dependency raise")
local code, out = child(helpers_path, "H.rtp()", "/nonexistent")
eq(ruling(code, out, "LIVE_SERVER_RTP is set but is not a directory: /nonexistent"), 1,
	"an override that is not a directory raises")

-- H.root follows the helper's own path, so a copy of it in a tree with no
-- ./live-server-rtp and no sibling clone finds nothing.
local bare = vim.fs.joinpath(H.tmpdir(), "mp")
vim.fn.mkdir(bare .. "/tests", "p")
assert(uv.fs_copyfile(helpers_path, bare .. "/tests/helpers.lua"))
code, out = child(bare .. "/tests/helpers.lua", "H.rtp()", "")
eq(ruling(code, out, "live-server.nvim not found"), 1, "no candidate on any lookup path raises")

H.section("Section 2: the path H.rtp() returns")
-- The override reaches the directory through "..", and its name carries a $.
local base = H.tmpdir()
local odd = base .. "/odd$HOME-x"
vim.fn.mkdir(odd, "p")
vim.fn.mkdir(base .. "/sub", "p")
_, out = child(helpers_path, 'print("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()', base .. "/sub/../odd$HOME-x")
eq(out:match("found=([^\r\n]*)"), odd, "an override comes back without /../ and without env expansion")

_, out = child(helpers_path, [[
print("found=" .. H.rtp())
print("source=" .. debug.getinfo(require("live_server.server").start, "S").source)
H.ok(true, "reached")
H.finish()]], "")
local found = out:match("found=([^\r\n]*)")
ok(found ~= nil and not found:find("/../", 1, true) and out:find("source=@" .. found .. "/lua/live_server/server.lua", 1, true) ~= nil,
	"the default path has no /../ and require loads from it")

H.finish()
