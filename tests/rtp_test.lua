-- tests/rtp_test.lua
-- Pin how H.rtp() proves the checkout and finds live-server.nvim: an override
-- that is not a directory, a missing dependency, and a checkout or a
-- directory the runtimepath does not resolve to raise instead of letting
-- require fall through to an installed copy; the chosen directory beats an
-- installed copy, ./live-server-rtp beats the sibling clone, and the path it
-- returns is absolute and normalized.
--
-- Run: nvim --headless -u NONE -l tests/rtp_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
-- The live-server this run found, for the cases that need a real one; every
-- other case runs H.rtp() in a child, so a raise here is caught, not fatal.
local found_ok, real_ls = pcall(H.rtp)

local uv = vim.uv or vim.loop
local ok, eq = H.ok, H.eq

-- One child of the same binary per case, since a raise ends the process that
-- runs it. Every child gets LIVE_SERVER_RTP (empty reads as unset), so a value
-- in the caller's environment never leaks into a case; vim.system reports a
-- child killed at the bound as exit 124.
local helpers_path = vim.fs.joinpath(H.root, "tests", "helpers.lua")
local CHILD_TIMEOUT_MS = 30000
local function child(helpers, body, override, env, cwd)
	local path = vim.fs.joinpath(H.tmpdir(), "child_test.lua")
	H.write_file(path, ("local H = dofile(%q)\n%s\n"):format(helpers, body))
	local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", path }, {
		env = vim.tbl_extend("force", env or {}, { LIVE_SERVER_RTP = override }),
		cwd = cwd,
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

-- The line a child printed after "name=".
local function printed(out, name)
	return out:match(name .. "=([^\r\n]*)")
end

-- live-server's modules under root (both unless files names some), enough
-- for the lookup and for require; the path in a loaded source names the copy.
local function stub(root, files)
	vim.fn.mkdir(root .. "/lua/live_server", "p")
	for _, name in ipairs(files or { "server", "util" }) do
		H.write_file(root .. "/lua/live_server/" .. name .. ".lua", "return { start = function() end }\n")
	end
end

-- A checkout of this plugin under root, holding a copy of the helper and the
-- entry file its root proof resolves; returns the copy's path.
local function tree(root)
	vim.fn.mkdir(root .. "/tests", "p")
	vim.fn.mkdir(root .. "/lua/markdown_preview", "p")
	assert(uv.fs_copyfile(helpers_path, root .. "/tests/helpers.lua"))
	H.write_file(root .. "/lua/markdown_preview/init.lua", "return {}\n")
	return root .. "/tests/helpers.lua"
end

-- The runtimepath reads a comma, a dollar sign or a glob character in an
-- entry as syntax, so a fixture under a temp path carrying one proves nothing
-- (measured with a comma in TMPDIR): such a run skips the case, counted.
local base = H.tmpdir()
local odd_temp = base:find("[,$*?%[%]{}]") ~= nil
local function fixture(msg, fn)
	if odd_temp then
		H.skip(msg .. " (the temp path " .. base .. " carries a comma, a dollar sign or a glob character)")
		return
	end
	fn(msg)
end

-- A start package on the child's own packpath: its data directory is
-- nvim-data on Windows and follows NVIM_APPNAME, so the child reports it.
local data = base .. "/data"
local child_data = printed(select(2, child(helpers_path, [[
io.stdout:write("data=" .. vim.fn.stdpath("data") .. "\n")
H.ok(true, "reported")
H.finish()]], "", { XDG_DATA_HOME = data })), "data")
local installed = child_data .. "/site/pack/t/start/installed"
stub(installed)

H.section("Section 1: a lookup that cannot be proven raises")
local code, out = child(helpers_path, "H.rtp()", "/nonexistent")
eq(ruling(code, out, "LIVE_SERVER_RTP is set but is not a directory: /nonexistent"), 1,
	"an override that is not a directory raises")

-- H.root follows the helper's own path, so a copy of it in a tree with no
-- ./live-server-rtp and no sibling clone finds nothing; the message names
-- where to clone from, the floor and both absolute paths.
fixture("no candidate on any lookup path raises, naming the clone, the floor and both paths", function(msg)
	local bare = base .. "/bare/mp"
	code, out = child(tree(bare), "H.rtp()", "")
	eq(ruling(code, out, ("live-server.nvim not found: clone https://github.com/selimacerbas/live-server.nvim (v1.5.0 or newer) to %s/live-server-rtp or %s/live-server.nvim"):format(bare, uv.fs_realpath(base .. "/bare"))), 1, msg)
end)

code, out = child(helpers_path, "H.rtp()", H.tmpdir())
eq(ruling(code, out, "does not resolve"), 1, "an empty override directory raises")

-- The runtimepath expands $HOME in the entry when it searches, so the stub
-- under the literal name is never the one resolved (measured) and require
-- would load the start package; the refusal names both.
fixture("an override with a $ in its name raises, naming the shadowing copy", function(msg)
	local odd = base .. "/odd$HOME-x"
	stub(odd)
	code, out = child(helpers_path, "H.rtp()", odd, { XDG_DATA_HOME = data })
	eq(ruling(code, out, ("live-server.nvim at %s does not resolve: %s/lua/live_server/server.lua"):format(odd, installed)), 1, msg)
end)

-- An override above a start package: the search resolves the package's
-- server.lua, whose path starts with the override's, so only equality with
-- the override's own file refuses it.
fixture("an override that holds an installed copy below it raises", function(msg)
	code, out = child(helpers_path, "H.rtp()", data, { XDG_DATA_HOME = data })
	eq(ruling(code, out, ("live-server.nvim at %s does not resolve: %s/lua/live_server/server.lua"):format(data, installed)), 1, msg)
end)

-- The plugin and server.lua both require util, so a directory holding
-- server.lua alone would load util from the start package (measured).
fixture("an override without util.lua raises, naming the copy util resolves to", function(msg)
	local partial = base .. "/partial"
	stub(partial, { "server" })
	code, out = child(helpers_path, "H.rtp()", partial, { XDG_DATA_HOME = data })
	eq(ruling(code, out, ("live-server.nvim at %s does not resolve: %s/lua/live_server/util.lua"):format(partial, installed)), 1, msg)
end)

-- A comma in the checkout's own path splits its entry, and require loaded an
-- installed copy of this plugin instead of the checkout (measured).
fixture("a checkout whose path the runtimepath splits raises, naming the installed copy", function(msg)
	local split = base .. "/a,b/mp"
	local installed_mp = child_data .. "/site/pack/t/start/installed-mp"
	vim.fn.mkdir(installed_mp .. "/lua/markdown_preview", "p")
	H.write_file(installed_mp .. "/lua/markdown_preview/init.lua", "return {}\n")
	code, out = child(tree(split), "H.rtp()", "", { XDG_DATA_HOME = data })
	eq(ruling(code, out, ("the checkout at %s does not resolve: %s/lua/markdown_preview/init.lua"):format(split, installed_mp)), 1, msg)
end)

-- The live-server directory goes before the checkout on the runtimepath, so
-- one that also carries this plugin's modules answered require while every
-- proof passed (measured); the root is proven again after the prepend.
fixture("a live-server directory that carries this plugin's modules raises, naming them", function(msg)
	local dep = base .. "/dep"
	stub(dep)
	vim.fn.mkdir(dep .. "/lua/markdown_preview", "p")
	H.write_file(dep .. "/lua/markdown_preview/init.lua", 'error("DEP COPY OF markdown_preview LOADED")\n')
	code, out = child(helpers_path, 'H.rtp()\nrequire("markdown_preview")\nH.ok(true, "loaded")\nH.finish()', dep)
	eq(ruling(code, out, ("the checkout at %s does not resolve: %s/lua/markdown_preview/init.lua"):format(H.root, dep)), 1, msg)
end)

H.section("Section 2: the directory H.rtp() chooses and the path it returns")
local plain = base .. "/plain"
stub(plain)
-- fnamemodify resolves a .. through the filesystem, as the directory check
-- read it, so the path comes back physical (measured: /var is /private/var
-- on macOS).
fixture("an override reached through .. comes back normalized", function(msg)
	vim.fn.mkdir(base .. "/sub", "p")
	out = select(2, child(helpers_path, 'print("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()', base .. "/sub/../plain"))
	eq(printed(out, "found"), uv.fs_realpath(base) .. "/plain", msg)
end)

-- The child's working directory is the physical path, so the absolute form
-- goes through realpath.
fixture("a relative override comes back absolute", function(msg)
	out = select(2, child(helpers_path, 'print("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()', "plain", nil, base))
	eq(printed(out, "found"), uv.fs_realpath(base) .. "/plain", msg)
end)

fixture("a symlinked checkout finds its physical sibling", function(msg)
	local phys = base .. "/phys"
	tree(phys .. "/mp")
	stub(phys .. "/live-server.nvim")
	vim.fn.mkdir(base .. "/links", "p")
	if not uv.fs_symlink(phys .. "/mp", base .. "/links/mp") then
		H.skip(msg .. " (fs_symlink failed on this platform)")
		return
	end
	out = select(2, child(base .. "/links/mp/tests/helpers.lua", 'print("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()', ""))
	eq(printed(out, "found"), uv.fs_realpath(phys) .. "/live-server.nvim", msg)
end)

-- Both default candidates exist in a copy of the tree, each a stub, so the
-- printed line and the loaded source say which one won.
fixture("./live-server-rtp beats the sibling clone", function(msg)
	local root = base .. "/order/mp"
	local helpers = tree(root)
	stub(root .. "/live-server-rtp")
	stub(base .. "/order/live-server.nvim")
	out = select(2, child(helpers, [[
H.rtp()
print("source=" .. debug.getinfo(require("live_server.server").start, "S").source)
H.ok(true, "reached")
H.finish()]], ""))
	eq(out:match("live%-server%.nvim: ([^\r\n]*)"), root .. "/live-server-rtp", msg .. ": the printed line names it")
	eq(printed(out, "source"), "@" .. root .. "/live-server-rtp/lua/live_server/server.lua", msg .. ": require loads it")
end)

-- An installed copy sits on the child's packpath beside a real live-server
-- at the override; prepend puts the override first, where append would let
-- the installed copy answer.
fixture("the chosen live-server beats an installed copy", function(msg)
	if not found_ok then
		H.skip(msg .. " (no live-server found: " .. tostring(real_ls):gsub("\n.*", "") .. ")")
		return
	end
	out = select(2, child(helpers_path, [[
H.rtp()
print("source=" .. debug.getinfo(require("live_server.server").start, "S").source)
H.ok(true, "reached")
H.finish()]], real_ls, { XDG_DATA_HOME = data }))
	eq(printed(out, "source"), "@" .. real_ls .. "/lua/live_server/server.lua", msg)
end)

-- The default candidates of this checkout; a contributor whose only
-- live-server is LIVE_SERVER_RTP has neither, which is no failure.
local ci_checkout = H.root .. "/live-server-rtp"
local sibling = vim.fs.dirname(uv.fs_realpath(H.root) or H.root) .. "/live-server.nvim"
if vim.fn.isdirectory(ci_checkout) == 1 or vim.fn.isdirectory(sibling) == 1 then
	out = select(2, child(helpers_path, [[
print("found=" .. H.rtp())
print("source=" .. debug.getinfo(require("live_server.server").start, "S").source)
H.ok(true, "reached")
H.finish()]], ""))
	local found = printed(out, "found")
	ok(found ~= nil and not found:find("/../", 1, true) and printed(out, "source") == "@" .. found .. "/lua/live_server/server.lua",
		"the default path has no /../ and require loads from it")
else
	H.skip("the default path (neither " .. ci_checkout .. " nor " .. sibling .. " exists)")
end

H.finish()
