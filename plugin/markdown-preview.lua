-- plugin/markdown-preview.lua
-- markdown-preview.nvim needs Neovim 0.10: vim.fs.joinpath, vim.uri_encode
-- and vim.uv. Refusing here spares an older Neovim a stack trace at first
-- use; above the load guard, a refusal leaves loaded_markdown_preview unset.
-- The notification waits for the source to return: lazy.nvim sources this
-- file with :source, where an ERROR notification on 0.9 raised Vim(source).
if vim.fn.has("nvim-0.10") == 0 then
	vim.schedule(function()
		vim.notify_once("markdown-preview.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
	end)
	return
end

if vim.g.loaded_markdown_preview then
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
