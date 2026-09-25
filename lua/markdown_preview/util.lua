-- lua/markdown_preview/util.lua
local M = {}

local sep = package.config:sub(1, 1)

local function dirname(path)
	return path:match("^(.*" .. sep .. ")") or "./"
end

function M.mkdirp(path)
	if vim.fn.isdirectory(path) == 0 then
		vim.fn.mkdir(path, "p")
	end
end

function M.file_exists(path)
	if not path then
		return false
	end
	local stat = vim.uv.fs_stat(path)
	return stat and stat.type == "file"
end

function M.write_text(path, text)
	M.mkdirp(dirname(path))
	local fd = assert(vim.uv.fs_open(path, "w", 420)) -- 0644
	assert(vim.uv.fs_write(fd, text, 0))
	assert(vim.uv.fs_close(fd))
end

function M.read_text(path)
	assert(type(path) == "string" and #path > 0, "read_text: path is nil")
	local fd = assert(vim.uv.fs_open(path, "r", 420))
	local stat = assert(vim.uv.fs_fstat(fd))
	local data = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return data
end

function M.copy_file(src, dst)
	assert(type(src) == "string" and #src > 0, "copy_file: source path is nil")
	local data = M.read_text(src)
	M.write_text(dst, data)
end

---Resolve a file shipped with the plugin using runtimepath first.
---@param rel string
---@return string|nil
function M.resolve_asset(rel)
	-- Prefer runtimepath discovery (robust across plugin managers and symlinks)
	local hits = vim.api.nvim_get_runtime_file(rel, false)
	if hits and #hits > 0 then
		return hits[1]
	end

	-- Fallback to path math from this file location
	local info = debug.getinfo(1, "S")
	local this = type(info.source) == "string" and info.source or ""
	if this:sub(1, 1) == "@" then
		this = this:sub(2)
	end
	local root = this:match("(.-)" .. sep .. "lua" .. sep .. "markdown_preview" .. sep .. "util%.lua$")
	if root then
		local candidate = table.concat({ root, rel }, sep)
		if M.file_exists(candidate) then
			return candidate
		end
	end
	return nil
end

---Launch a detached command; true when the process spawned.
---(vim.fn.jobstart raises for a non-executable command, so pcall it.)
local function try_launch(cmd, opts)
	local ok, job = pcall(vim.fn.jobstart, cmd, opts or { detach = true })
	return ok and job > 0
end

---Open a URL in the browser.
---@param url string
---@param browser string|table|nil Optional override. String = browser name/binary.
---  Table = full command (URL appended). nil = system default.
function M.open_in_browser(url, browser)
	local function warn(what)
		vim.notify(("Markdown Preview: %s.\nOpen manually: %s"):format(what, url), vim.log.levels.WARN)
	end

	if browser then
		local cmd
		local opts = { detach = true }
		if type(browser) == "table" then
			cmd = vim.list_extend(vim.deepcopy(browser), { url })
		elseif vim.fn.has("mac") == 1 then
			-- On macOS, `open -a` resolves app names like "Firefox" or
			-- "Google Chrome". The spawn succeeds even when the app doesn't
			-- exist (`open` itself exits non-zero), so check the exit code.
			cmd = { "open", "-a", browser, url }
			opts.on_exit = function(_, code)
				if code ~= 0 then
					vim.schedule(function()
						warn(('configured browser "%s" could not be opened'):format(browser))
					end)
				end
			end
		else
			cmd = { browser, url }
		end
		if not try_launch(cmd, opts) then
			warn(
				("could not launch configured browser (%s)"):format(type(browser) == "table" and browser[1] or browser)
			)
		end
		return
	end

	local candidates
	if vim.fn.has("mac") == 1 then
		candidates = { { "open", url } }
	elseif vim.fn.has("wsl") == 1 then
		-- WSL: Windows interop may be disabled or off PATH (issue #26), so
		-- try the usual launchers in order instead of assuming one works.
		candidates = {
			{ "wslview", url },
			{ "explorer.exe", url },
			{ "powershell.exe", "-NoProfile", "-Command", "Start-Process '" .. url .. "'" },
		}
	elseif vim.fn.has("unix") == 1 then
		candidates = { { "xdg-open", url } }
	elseif vim.fn.has("win32") == 1 then
		candidates = { { "cmd.exe", "/c", "start", url } }
	else
		candidates = {}
	end

	for _, cmd in ipairs(candidates) do
		if vim.fn.executable(cmd[1]) == 1 and try_launch(cmd) then
			return
		end
	end
	warn("could not open a browser automatically")
end

---Generate a per-buffer workspace directory under Neovim's cache.
---@param bufnr integer
---@return string
function M.workspace_for_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local hash = vim.fn.sha256(name):sub(1, 12)
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", hash)
end

function M.shared_workspace()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "shared")
end

return M
