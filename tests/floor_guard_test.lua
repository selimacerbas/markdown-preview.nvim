-- tests/floor_guard_test.lua
-- Below Neovim 0.10 the plugin file defines no command and the module
-- answers a config's setup() without loading the plugin or live-server (one
-- ERROR notification between them); on a supported version the commands are
-- defined.
--
-- Run: nvim --headless -u NONE -l tests/floor_guard_test.lua
-- live-server.nvim is found by tests/helpers.lua ($LIVE_SERVER_RTP,
-- ./live-server-rtp, the checkout's sibling live-server.nvim).
local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()
local plugin_file = H.root .. "/plugin/markdown-preview.lua"

-- Every refusal is recorded, notify_once's own dedupe aside, so the plugin
-- file's and the module's are checked apart.
local notices = {}
local real_once = vim.notify_once
vim.notify_once = function(msg, level)
	notices[#notices + 1] = { msg = msg, level = level }
end
local real_has = vim.fn.has
vim.fn.has = function(feature)
	if feature == "nvim-0.10" then
		return 0
	end
	return real_has(feature)
end

H.section("Section 1: below the floor")
vim.cmd("source " .. vim.fn.fnameescape(plugin_file))
H.eq(vim.fn.exists(":MarkdownPreview"), 0, "no command is defined below the floor")
-- lazy.nvim sources plugin files with :source, where an ERROR notification
-- on 0.9 raised a Vim(source) exception, so the refusal waits for the source
-- to return and shows once the loop turns.
H.eq(#notices, 0, "the plugin file's refusal waits until the :source returns")
vim.wait(1000, function()
	return #notices > 0
end)
H.eq(#notices, 1, "the plugin file refuses with one notification")
-- A refusal that set the load guard would keep a later source on a
-- supported Neovim from defining the commands.
H.eq(vim.g.loaded_markdown_preview, nil, "a refused load leaves the load guard unset")
-- lazy.nvim's config calls setup() whatever the plugin file did.
package.loaded["markdown_preview"] = nil
local setup_ok, setup_err = pcall(function()
	require("markdown_preview").setup({})
end)
H.ok(setup_ok, "setup() raises nothing below the floor" .. (setup_ok and "" or (": " .. tostring(setup_err))))
H.ok(
	package.loaded["markdown_preview.util"] == nil and package.loaded["live_server.server"] == nil,
	"the module returns before its own modules and live-server's, and vim.uv, load"
)
-- A lazy load on FileType runs the module inside 0.9's filetype nvim_cmd,
-- where an ERROR notification raised Vim(append), so this refusal waits too.
H.eq(#notices, 1, "the module's refusal waits until the require returns")
vim.wait(1000, function()
	return #notices > 1
end)
H.eq(#notices, 2, "the module refuses with one notification too")
-- Any other field a config calls answers the same, never a nil.
local other_ok, other = pcall(function()
	return require("markdown_preview").anything_else()
end)
H.eq(other_ok and other or ("raised " .. tostring(other)), "", "an undocumented field on the stub answers the same")
-- notify_once shows a text once, so one text between the two refusals is
-- one notification on screen, whichever of them runs first.
local texts, all_errors = {}, #notices > 0
for _, notice in ipairs(notices) do
	texts[notice.msg] = true
	all_errors = all_errors and notice.level == vim.log.levels.ERROR
end
H.eq(vim.tbl_count(texts), 1, "the two refusals are one text, so the user sees one notification")
H.ok(notices[1] ~= nil and notices[1].msg:find("0.10", 1, true) ~= nil, "the notification names the floor")
H.ok(all_errors, "every refusal is an ERROR")

H.section("Section 2: at the floor")
vim.fn.has = real_has
vim.notify_once = real_once
vim.g.loaded_markdown_preview = nil
-- The stub goes, and so does the sentinel require leaves for a module that
-- raised while loading.
for _, modname in ipairs({ "markdown_preview", "live_server.server", "live_server.util" }) do
	package.loaded[modname] = nil
end
vim.cmd("source " .. vim.fn.fnameescape(plugin_file))
-- By type: a left-over stub answers config with a function.
H.ok(
	type(require("markdown_preview").config) == "table" and type(package.loaded["live_server.server"]) == "table",
	"the plugin's own modules and live-server's load on a supported Neovim"
)
H.eq(vim.fn.exists(":MarkdownPreview"), 2, "the commands are defined on a supported Neovim")
H.eq(vim.fn.exists(":MarkdownPreviewStop"), 2, "every command is defined")
H.finish()
