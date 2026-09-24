-- tests/parse_test.lua
-- Every tracked Lua file parses under this Neovim's LuaJIT. No other suite
-- loads the plugin's entry module or plugin/, so a parse error there passed
-- every job; the list is git's, so an untracked file never enters and a
-- checkout without git fails here instead of checking nothing.
--
-- Run: nvim --headless -u NONE -l tests/parse_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()

H.section("Section 1: every tracked Lua file parses")
local listed = vim.system({ "git", "ls-files", "-z", "--", "*.lua" }, { cwd = H.root, text = true }):wait()
local git_exit = H.exit_code(listed)
H.ok(
	git_exit == 0,
	"git lists the tracked Lua files" .. (git_exit ~= 0 and (": " .. vim.trim(listed.stderr or "")) or "")
)
local files = vim.split(listed.stdout or "", "\0", { plain = true, trimempty = true })
H.ok(#files > 0, ("git lists %d tracked Lua files"):format(#files))
for _, rel in ipairs(files) do
	local chunk, err = loadfile(H.root .. "/" .. rel)
	H.ok(chunk ~= nil, rel .. " parses" .. (err and (": " .. err) or ""))
end

H.finish()
