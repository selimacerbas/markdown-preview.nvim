-- lua/markdown_preview/floor.lua
-- The one statement of the Neovim floor, read by the plugin file and the
-- module. It loads on any Neovim that sources a Lua plugin file (0.5 on),
-- so it calls nothing newer, and the version is read first: before 0.8 there
-- is no vim.fs to index, and a config that polyfills vim.uv = vim.loop there
-- got past a vim.uv test into that index (measured on 0.7.2 and 0.6.1). The
-- three APIs the plugin needs are tested beside the version, since a
-- 0.10.0-dev build from before August 2023 answers has("nvim-0.10") without
-- all of them.
return {
	ok = vim.fn.has("nvim-0.10") == 1 and vim.uv ~= nil and vim.fs.joinpath ~= nil and vim.uri_encode ~= nil,
	message = "markdown-preview.nvim requires Neovim 0.10 or newer",
}
