-- lua/markdown_preview/init.lua
local ts = require("markdown_preview.ts")
local util = require("markdown_preview.util")
local ls_server = require("live_server.server")

local M = {}

M.config = {
	port = 8421,
	open_browser = true,

	content_name = "content.md",
	index_name = "index.html",

	-- nil = per-buffer workspace (recommended); set a path to override
	workspace_dir = nil,

	overwrite_index_on_start = true,

	auto_refresh = true,
	auto_refresh_events = { "InsertLeave", "TextChanged", "TextChangedI", "BufWritePost" },
	debounce_ms = 300,
	notify_on_refresh = false,

	-- "js" = browser-side mermaid.js (default, zero deps)
	-- "rust" = pre-render via mermaid-rs-renderer (mmdr) CLI (~400x faster)
	mermaid_renderer = "js",

	scroll_sync = true, -- sync browser scroll to cursor heading
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	M._mmdr_available = nil -- reset so next check re-probes
end

-- Internal state
M._augroup = nil
M._active_bufnr = nil
M._last_text_by_buf = {}
M._server_instance = nil
M._debounce_seq = 0
M._workspace_dir = nil
M._mmdr_available = nil -- nil = unchecked, true/false after probe
M._last_heading_id = nil

---------------------------------------------------------------------------
-- Workspace
---------------------------------------------------------------------------

local function resolve_workspace(bufnr)
	if M.config.workspace_dir then
		return M.config.workspace_dir
	end
	return util.workspace_for_buffer(bufnr)
end

local function ensure_workspace(bufnr)
	local dir = resolve_workspace(bufnr)
	util.mkdirp(dir)
	return dir
end

---------------------------------------------------------------------------
-- Index HTML
---------------------------------------------------------------------------

local function write_index(dir)
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	local src = util.resolve_asset("assets/index.html")
	if not src then
		error("Could not locate assets/index.html in runtimepath. Make sure the plugin ships it.")
	end
	util.copy_file(src, dst)
	return dst
end

local function write_index_if_needed(dir)
	if M.config.overwrite_index_on_start then
		return write_index(dir)
	end
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	if not util.file_exists(dst) then
		return write_index(dir)
	end
	return dst
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

local function extract_mermaid_under_cursor_strict(bufnr)
	local ok, text = pcall(ts.extract_under_cursor, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
end

local function extract_mermaid_under_cursor(bufnr)
	local text = extract_mermaid_under_cursor_strict(bufnr)
	if text and #text > 0 then
		return text
	end
	local fallback = ts.fallback_scan(bufnr)
	if not fallback or #fallback == 0 then
		error("No ```mermaid fenced code block found under (or above) the cursor")
	end
	return fallback
end

---------------------------------------------------------------------------
-- mermaid-rs-renderer (mmdr) integration
---------------------------------------------------------------------------

---Check if mmdr CLI is available; caches result after first probe.
---@return boolean
local function is_mmdr_available()
	if M._mmdr_available ~= nil then
		return M._mmdr_available
	end
	M._mmdr_available = vim.fn.executable("mmdr") == 1
	if not M._mmdr_available then
		vim.notify(
			"Markdown Preview: mermaid_renderer='rust' but `mmdr` not found in PATH.\n"
				.. "Install: cargo install mermaid-rs-renderer\n"
				.. "Falling back to browser-side mermaid.js.",
			vim.log.levels.WARN
		)
	end
	return M._mmdr_available
end

---Render a single mermaid diagram source via mmdr CLI.
---@param source string Raw mermaid diagram text
---@return string|nil svg SVG string on success
---@return string|nil err Error message on failure
local function render_mermaid_via_mmdr(source)
	local result = vim.fn.system({ "mmdr", "-e", "svg" }, source)
	if vim.v.shell_error ~= 0 then
		return nil, result
	end
	return result, nil
end

-- Expand button SVG used in pre-rendered blocks (matches browser-side fence renderer)
local EXPAND_BTN_SVG = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none">'
	.. '<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
	.. "</svg>"

---Pre-render ```mermaid fences via mmdr, replacing them with HTML blocks.
---Failed renders leave the original fence untouched for browser-side fallback.
---@param text string Full markdown text
---@return string text Markdown with pre-rendered mermaid blocks
local function prerender_mermaid_blocks(text)
	local rust_idx = 0
	local out = {}
	local pos = 1

	while true do
		-- Find opening ```mermaid fence
		local fence_start, fence_end = text:find("\n```mermaid%s*\n", pos)
		if not fence_start then
			-- Also check at the very start of the document
			if pos == 1 then
				fence_start, fence_end = text:find("^```mermaid%s*\n")
			end
			if not fence_start then
				break
			end
		end

		-- Find closing ```
		local close_start, close_end = text:find("\n```%s*\n", fence_end)
		if not close_start then
			-- Try closing at end of file
			close_start, close_end = text:find("\n```%s*$", fence_end)
			if not close_start then
				break
			end
		end

		-- Extract mermaid source between fences
		local source = text:sub(fence_end + 1, close_start - 1)
		if source and #source > 0 then
			local svg, _err = render_mermaid_via_mmdr(source)
			if svg then
				rust_idx = rust_idx + 1
				local block_id = "mmd-rust-" .. rust_idx
				local encoded = vim.uri_encode(source, "rfc2396")

				local html_block = '<div class="mermaid-block mermaid-rendered" id="'
					.. block_id
					.. '" data-mermaid-source="'
					.. encoded
					.. '" data-graph="mermaid" data-prerendered="true">'
					.. '<button class="mermaid-expand-btn" title="Expand diagram" data-expand="'
					.. block_id
					.. '">'
					.. EXPAND_BTN_SVG
					.. "</button>"
					.. '<div class="mermaid-svg-wrap">'
					.. svg
					.. "</div>"
					.. "</div>"

				-- Append text before fence + the HTML block
				out[#out + 1] = text:sub(pos, fence_start - 1)
				out[#out + 1] = "\n" .. html_block .. "\n"
				pos = close_end + 1
			else
				-- mmdr failed for this block — leave fence untouched for JS fallback
				out[#out + 1] = text:sub(pos, close_end)
				pos = close_end + 1
			end
		else
			out[#out + 1] = text:sub(pos, close_end)
			pos = close_end + 1
		end
	end

	-- Append remaining text
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

---Get the content to write based on filetype.
---Markdown buffers: entire buffer.
---Mermaid files (.mmd, .mermaid): entire buffer wrapped in mermaid fence.
---Others: mermaid block under cursor wrapped in fence.
---@param bufnr integer
---@return string
local function get_content(bufnr)
	local text
	local ft = vim.bo[bufnr].filetype
	if ft == "markdown" then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = table.concat(lines, "\n")
	elseif vim.api.nvim_buf_get_name(bufnr):match("%.mmd$")
		or vim.api.nvim_buf_get_name(bufnr):match("%.mermaid$") then
		-- .mmd / .mermaid files: treat entire buffer as mermaid
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = "```mermaid\n" .. table.concat(lines, "\n") .. "\n```\n"
	else
		-- Other filetypes: extract mermaid block under cursor, wrap in code fence
		local mermaid_text = extract_mermaid_under_cursor(bufnr)
		text = "```mermaid\n" .. mermaid_text .. "\n```\n"
	end

	-- Pre-render mermaid blocks via mmdr if configured
	if M.config.mermaid_renderer == "rust" and is_mmdr_available() then
		text = prerender_mermaid_blocks(text)
	end

	return text
end

---Same as get_content but never errors (returns nil on failure).
---@param bufnr integer
---@return string|nil
local function get_content_safe(bufnr)
	local ok, text = pcall(get_content, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
end

local function write_content(dir, text)
	local path = vim.fs.joinpath(dir, M.config.content_name)
	util.write_text(path, text)
	return path
end

---------------------------------------------------------------------------
-- Refresh logic
---------------------------------------------------------------------------

local function maybe_refresh(bufnr, silent)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local text = get_content_safe(bufnr)
	if not text then
		return false
	end

	if M._last_text_by_buf[bufnr] == text then
		return false
	end

	local dir = ensure_workspace(bufnr)
	write_content(dir, text)
	M._last_text_by_buf[bufnr] = text

	-- Notify live-server of the content change for immediate SSE push
	if M._server_instance then
		pcall(ls_server.reload, M._server_instance, M.config.content_name)
	end

	if not silent and M.config.notify_on_refresh then
		vim.notify("Markdown preview updated", vim.log.levels.INFO)
	end
	return true
end

local function debounced_refresh(bufnr)
	M._debounce_seq = M._debounce_seq + 1
	local this_call = M._debounce_seq
	vim.defer_fn(function()
		if this_call ~= M._debounce_seq then
			return
		end
		pcall(maybe_refresh, bufnr, true)
	end, M.config.debounce_ms)
end

---------------------------------------------------------------------------
-- Scroll sync (heading-based)
---------------------------------------------------------------------------

--- Slugify a heading string — must match browser-side markdown-it-anchor slugify:
---   s.trim().toLowerCase().replace(/\s+/g, '-').replace(/[^\w-]/g, '')
local function slugify(s)
	return s:match("^%s*(.-)%s*$"):lower():gsub("%s+", "-"):gsub("[^%w%-]", "")
end

--- Find the nearest heading above (or at) the cursor and return its slug.
local function find_heading_at_cursor(bufnr)
	local row = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
	for i = #lines, 1, -1 do
		local text = lines[i]:match("^#{1,6}%s+(.+)")
		if text then
			return slugify(text)
		end
	end
	return nil
end

--- Send a scroll SSE event if the heading under the cursor changed.
local function send_scroll_sync(bufnr)
	if not M.config.scroll_sync then return end
	if not M._server_instance then return end
	local id = find_heading_at_cursor(bufnr)
	if not id or id == M._last_heading_id then return end
	M._last_heading_id = id
	local payload = vim.json.encode({ headingId = id })
	pcall(ls_server.send_event, M._server_instance, "scroll", payload)
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

local function set_autocmds_for_buffer(bufnr)
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
	end
	M._augroup = vim.api.nvim_create_augroup("MarkdownPreviewAuto", { clear = true })

	if M.config.auto_refresh then
		for _, ev in ipairs(M.config.auto_refresh_events) do
			vim.api.nvim_create_autocmd(ev, {
				group = M._augroup,
				buffer = bufnr,
				callback = function()
					debounced_refresh(bufnr)
				end,
				desc = "Markdown Preview auto-refresh (debounced)",
			})
		end
	end

	for _, ev in ipairs({ "CursorMoved", "CursorMovedI" }) do
		vim.api.nvim_create_autocmd(ev, {
			group = M._augroup,
			buffer = bufnr,
			callback = function() send_scroll_sync(bufnr) end,
			desc = "Markdown Preview scroll sync",
		})
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.start()
	local bufnr = vim.api.nvim_get_current_buf()
	M._active_bufnr = bufnr

	local ok_content, text = pcall(get_content, bufnr)
	if not ok_content then
		vim.notify("Markdown Preview: " .. tostring(text), vim.log.levels.ERROR)
		return
	end
	local dir = ensure_workspace(bufnr)
	M._workspace_dir = dir

	write_index_if_needed(dir)
	write_content(dir, text)
	M._last_text_by_buf[bufnr] = text

	set_autocmds_for_buffer(bufnr)

	-- Start live-server if not already running
	if not M._server_instance then
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		local ok, inst = pcall(ls_server.start, {
			port = M.config.port,
			root = dir,
			default_index = index_path,
			headers = { ["Cache-Control"] = "no-cache" },
			cors = true,
			live = {
				enabled = true,
				inject_script = false,
				debounce = 100,
			},
			features = { dirlist = { enabled = false } },
		})
		if not ok then
			vim.notify(
				("Markdown Preview: failed to start server on port %d — %s"):format(M.config.port, tostring(inst)),
				vim.log.levels.ERROR
			)
			return
		end
		M._server_instance = inst

		if M.config.open_browser then
			vim.defer_fn(function()
				util.open_in_browser(("http://127.0.0.1:%d/"):format(M.config.port))
			end, 200)
		end
	else
		-- Server already running — retarget to this buffer's workspace
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		pcall(ls_server.update_target, M._server_instance, dir, index_path)
		pcall(ls_server.reload, M._server_instance, M.config.content_name)

		-- No browser tab connected (user closed it)? Re-open.
		if M.config.open_browser and ls_server.connected_client_count(M._server_instance) == 0 then
			vim.defer_fn(function()
				util.open_in_browser(("http://127.0.0.1:%d/"):format(M.config.port))
			end, 200)
		end
	end
end

function M.refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	local changed = maybe_refresh(bufnr, false)
	if not changed and M.config.notify_on_refresh then
		vim.notify("Markdown Preview: no changes detected", vim.log.levels.INFO)
	end
end

function M.stop()
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
		M._augroup = nil
	end
	if M._server_instance then
		pcall(ls_server.stop, M._server_instance)
		M._server_instance = nil
	end
	M._workspace_dir = nil
	M._last_heading_id = nil
end

return M
