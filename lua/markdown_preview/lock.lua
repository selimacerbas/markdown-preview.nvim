-- lua/markdown_preview/lock.lua
local uv = vim.loop

local M = {}

local function lock_path()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")
end

function M.read()
	local path = lock_path()
	local fd = uv.fs_open(path, "r", 420)
	if not fd then return nil end
	local stat = uv.fs_fstat(fd)
	if not stat then uv.fs_close(fd); return nil end
	local data = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if not data then return nil end
	local ok, tbl = pcall(vim.json.decode, data)
	if not ok or type(tbl) ~= "table" then return nil end
	return tbl
end

function M.write(port, workspace, token)
	local path = lock_path()
	local dir = path:match("^(.+)/[^/]+$")
	if dir and vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local json = vim.json.encode({
		port = port,
		workspace = workspace,
		pid = vim.fn.getpid(),
		token = token, -- nil OK; secondary instances need this to hit /__live/inject
	})
	-- Mode 0600 (decimal 384) so the token isn't world-readable on multi-user
	-- systems. Use fs_open + immediate truncate so older lockfiles with looser
	-- modes get replaced cleanly.
	local fd = assert(uv.fs_open(path, "w", 384))
	assert(uv.fs_write(fd, json, 0))
	assert(uv.fs_close(fd))
end

function M.remove()
	pcall(uv.fs_unlink, lock_path())
end

function M.is_server_alive(port)
	local alive = nil
	local tcp = uv.new_tcp()
	tcp:connect("127.0.0.1", port, function(err)
		alive = not err
		pcall(function() tcp:shutdown() end)
		pcall(function() tcp:close() end)
	end)
	vim.wait(500, function() return alive ~= nil end, 10)
	if alive == nil then
		pcall(function() tcp:close() end)
		alive = false
	end
	return alive
end

return M
