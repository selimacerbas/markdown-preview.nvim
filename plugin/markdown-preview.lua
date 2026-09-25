-- plugin/markdown-preview.lua
-- A config that sets loaded_markdown_preview has opted out, on any Neovim,
-- so the variable is read before the floor and nothing is said.
if vim.g.loaded_markdown_preview then
	return
end

-- markdown-preview.nvim needs Neovim 0.10: vim.fs.joinpath, vim.uri_encode
-- and vim.uv. Below the floor every documented command is still defined, as
-- a refuser, so a lazy.nvim cmd or keys spec finds its command and each use
-- says why, and one notification says it at load; the load guard stays
-- unset, since the plugin has not loaded. Both wait for the loop: lazy.nvim
-- sources this file with :source and runs a cmd spec's command through
-- vim.cmd, where an ERROR notification on 0.9 raised Vim(source) or a
-- traceback through lazy's handler (measured).
local floor = require("markdown_preview.floor")
if not floor.ok then
	local function refuse()
		vim.schedule(function()
			vim.notify(floor.message, vim.log.levels.ERROR)
		end)
	end
	-- Lua user commands and notify_once arrived in 0.7, and this file is
	-- sourced from 0.5 on, where the notification at load is all there is.
	if vim.api.nvim_create_user_command then
		for _, name in ipairs({ "MarkdownPreview", "MarkdownPreviewRefresh", "MarkdownPreviewStop" }) do
			vim.api.nvim_create_user_command(name, refuse, { desc = "Markdown: requires Neovim 0.10" })
		end
	end
	vim.schedule(function()
		local notify = vim.notify_once or vim.notify
		notify(floor.message, vim.log.levels.ERROR)
	end)
	return
end
vim.g.loaded_markdown_preview = true

-- User commands
vim.api.nvim_create_user_command("MarkdownPreview", function()
	require("markdown_preview").start()
end, {})

vim.api.nvim_create_user_command("MarkdownPreviewRefresh", function()
	require("markdown_preview").refresh()
end, {})

vim.api.nvim_create_user_command("MarkdownPreviewStop", function()
	require("markdown_preview").stop()
end, {})
