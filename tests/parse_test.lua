-- tests/parse_test.lua
-- Every tracked Lua file parses under this Neovim's LuaJIT. A file no other
-- suite loads is parsed here too, so a parse error in it cannot pass every
-- job; the list is git's, so an untracked file never enters and a tree
-- without git's index (a git archive copy, a tarball) fails here, saying
-- so, instead of checking nothing.
--
-- Run: nvim --headless -u NONE -l tests/parse_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()

H.section("Section 1: every tracked Lua file parses")
local listed = vim.system({ "git", "ls-files", "-z", "--", "*.lua" }, { cwd = H.root, text = true }):wait()
local git_exit = H.exit_code(listed)
local why = ""
if git_exit ~= 0 then
	why = " (this suite needs a git checkout; a git archive copy or a tarball has no index): "
		.. vim.trim(listed.stderr or "")
end
H.ok(git_exit == 0, "git lists the tracked Lua files" .. why)
local files = vim.split(listed.stdout or "", "\0", { plain = true, trimempty = true })
H.ok(#files > 0, ("git lists %d tracked Lua files"):format(#files))
for _, rel in ipairs(files) do
	local chunk, err = loadfile(H.root .. "/" .. rel)
	H.ok(chunk ~= nil, rel .. " parses" .. (err and (": " .. err) or ""))
end

-- A wrong repository name or a self-named entry in lazy.lua would make
-- lazy.nvim install the wrong plugin or clone upstream beside the user's
-- copy, so its content is pinned whole.
H.section("Section 2: lazy.lua declares live-server.nvim alone")
local ok_lazy, spec = pcall(dofile, H.root .. "/lazy.lua")
H.ok(ok_lazy, "lazy.lua loads" .. (ok_lazy and "" or (": " .. tostring(spec))))
local entry = ok_lazy and type(spec) == "table" and spec[1] or nil
H.ok(
	type(spec) == "table" and vim.tbl_count(spec) == 1 and type(entry) == "table",
	"lazy.lua returns a table of exactly one spec"
)
H.ok(
	type(entry) == "table" and entry[1] == "selimacerbas/live-server.nvim" and vim.tbl_count(entry) == 1,
	'the spec is { "selimacerbas/live-server.nvim" } with no other key'
)

H.finish()
