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

function M.write(port, workspace)
	local path = lock_path()
	local dir = path:match("^(.+)/[^/]+$")
	if dir and vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local json = vim.json.encode({ port = port, workspace = workspace, pid = vim.fn.getpid() })
	local fd = assert(uv.fs_open(path, "w", 420))
	assert(uv.fs_write(fd, json, 0))
	assert(uv.fs_close(fd))
end

function M.remove()
	pcall(uv.fs_unlink, lock_path())
end

--- Check whether a process is still running.
--- Uses signal 0 (no-op) which succeeds only if the process exists.
--- Returns false for PIDs that have exited (zombies reaped) or don't exist.
---@param pid integer
---@return boolean
function M.is_pid_alive(pid)
	local ok = uv.kill(pid, 0)
	return ok ~= nil
end

function M.is_server_alive(host, port, expected_pid)
	-- If the PID that wrote the lock is dead, don't trust the port — another
	-- process may have reused it. Treat the lock as stale.
	if expected_pid and not M.is_pid_alive(expected_pid) then
		return false
	end
	local alive = nil
	local tcp = uv.new_tcp()
	tcp:connect(host, port, function(err)
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
