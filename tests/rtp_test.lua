-- tests/rtp_test.lua
-- Pin how H.rtp() finds live-server.nvim: an override that is not a directory,
-- a missing dependency and a directory the runtimepath does not resolve to
-- raise instead of letting require fall through to an installed copy, and the
-- path it returns is normalized.
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
local function child(helpers, body, override, env)
	local path = vim.fs.joinpath(H.tmpdir(), "child_test.lua")
	H.write_file(path, ("local H = dofile(%q)\n%s\n"):format(helpers, body))
	local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", path }, {
		env = vim.tbl_extend("force", env or {}, { LIVE_SERVER_RTP = override }),
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

-- A live_server/server.lua under root, enough for the lookup and for require.
local function stub(root)
	vim.fn.mkdir(root .. "/lua/live_server", "p")
	H.write_file(root .. "/lua/live_server/server.lua", "return { start = function() end }\n")
end

H.section("Section 1: a lookup that cannot be proven raises")
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

code, out = child(helpers_path, "H.rtp()", H.tmpdir())
eq(ruling(code, out, "does not resolve"), 1, "an empty override directory raises")

-- The runtimepath expands $HOME in the entry when it searches, so the stub
-- under the literal name is never the one resolved (measured) and require
-- would load the start package under XDG_DATA_HOME; the refusal names both.
local base = H.tmpdir()
local odd = base .. "/odd$HOME-x"
stub(odd)
local data = base .. "/data"
local installed = data .. "/nvim/site/pack/t/start/installed"
stub(installed)
code, out = child(helpers_path, "H.rtp()", odd, { XDG_DATA_HOME = data })
eq(ruling(code, out, ("live-server.nvim at %s does not resolve: %s/lua/live_server/server.lua"):format(odd, installed)), 1,
	"an override with a $ in its name raises, naming the shadowing copy")

H.section("Section 2: the path H.rtp() returns")
local _
local plain = base .. "/plain"
stub(plain)
vim.fn.mkdir(base .. "/sub", "p")
_, out = child(helpers_path, 'print("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()', base .. "/sub/../plain")
eq(out:match("found=([^\r\n]*)"), plain, "an override reached through .. comes back normalized")

_, out = child(helpers_path, [[
print("found=" .. H.rtp())
print("source=" .. debug.getinfo(require("live_server.server").start, "S").source)
H.ok(true, "reached")
H.finish()]], "")
local found = out:match("found=([^\r\n]*)")
ok(found ~= nil and not found:find("/../", 1, true) and out:find("source=@" .. found .. "/lua/live_server/server.lua", 1, true) ~= nil,
	"the default path has no /../ and require loads from it")

H.finish()
