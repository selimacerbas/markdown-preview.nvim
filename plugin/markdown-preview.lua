-- plugin/markdown-preview.lua
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
