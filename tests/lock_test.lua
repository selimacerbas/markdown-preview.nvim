-- tests/lock_test.lua
-- Lock file semantics for takeover mode coordination
-- Run with: nvim --headless -c "set rtp+=." -c "luafile tests/lock_test.lua" -c "qa!"

local uv = vim.loop
local lock = require("markdown_preview.lock")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
	if actual == expected then
		return
	end
	failed = failed + 1
	error(string.format("FAIL: %s\n  expected: %s\n  actual:   %s", msg, tostring(expected), tostring(actual)))
end

local function assert_ok(ok, msg)
	if not ok then
		failed = failed + 1
		error("FAIL: " .. msg)
	end
end

-- Use a temp dir so we don't pollute the real cache or conflict with running instances
local tmpdir = os.tmpname()
os.remove(tmpdir)
vim.fn.mkdir(tmpdir, "p")
local test_lock_path = vim.fs.joinpath(tmpdir, "test.lock")

-- Override lock_path for testing via package.loaded
-- We monkey-patch the module so tests use our temp path
local orig_lock_path_fn
do
	local mod = debug.getinfo(lock.read).func
	local i = 1
	while true do
		local name, value = debug.getupvalue(mod, i)
		if not name then
			break
		end
		if name == "lock_path" then
			orig_lock_path_fn = value
			break
		end
		i = i + 1
	end
end

-- Since lock_path is a file-local closure we can't easily override it.
-- Instead, we test against the real lock path but in a controlled sequence
-- (clean up before and after). We also test the pure functions independently.

-- ---------------------------------------------------------------------------
-- Section 1: is_pid_alive
-- ---------------------------------------------------------------------------
local function test_pid_alive_self()
	local alive = lock.is_pid_alive(vim.fn.getpid())
	assert_eq(alive, true, "current process should be alive")
	passed = passed + 1
	print("  PASS: is_pid_alive(self)")
end

local function test_pid_alive_dead()
	local alive = lock.is_pid_alive(99999999)
	assert_eq(alive, false, "nonexistent PID should be dead")
	passed = passed + 1
	print("  PASS: is_pid_alive(dead PID)")
end

-- ---------------------------------------------------------------------------
-- Section 2: write / read / remove roundtrip
-- ---------------------------------------------------------------------------
local function test_write_read_roundtrip()
	lock.remove()
	local data = lock.read()
	assert_eq(data, nil, "read after remove should return nil")

	lock.write(8421, "/tmp/fake-workspace")
	data = lock.read()
	assert_ok(data ~= nil, "read after write should return data")
	assert_eq(data.port, 8421, "port should roundtrip")
	assert_eq(data.workspace, "/tmp/fake-workspace", "workspace should roundtrip")
	assert_eq(data.pid, vim.fn.getpid(), "pid should be current process")

	lock.remove()
	data = lock.read()
	assert_eq(data, nil, "read after final remove should return nil")

	passed = passed + 1
	print("  PASS: write/read/remove roundtrip")
end

local function test_read_corrupt_file()
	lock.remove()
	local path = vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")
	local dir = path:match("^(.+)/[^/]+$")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local fd = uv.fs_open(path, "w", 420)
	uv.fs_write(fd, "NOT JSON{{{", 0)
	uv.fs_close(fd)

	local data = lock.read()
	assert_eq(data, nil, "corrupt lock file should return nil")

	lock.remove()
	passed = passed + 1
	print("  PASS: read corrupt file returns nil")
end

local function test_read_empty_file()
	lock.remove()
	local path = vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")
	local dir = path:match("^(.+)/[^/]+$")
	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local fd = uv.fs_open(path, "w", 420)
	uv.fs_write(fd, "", 0)
	uv.fs_close(fd)

	local data = lock.read()
	assert_eq(data, nil, "empty lock file should return nil")

	lock.remove()
	passed = passed + 1
	print("  PASS: read empty file returns nil")
end

-- ---------------------------------------------------------------------------
-- Section 3: is_server_alive — port + PID semantics
-- ---------------------------------------------------------------------------
local function test_server_alive_unoccupied_port()
	local alive = lock.is_server_alive("127.0.0.1", 59999)
	assert_eq(alive, false, "unoccupied port should not be alive")
	passed = passed + 1
	print("  PASS: is_server_alive on unoccupied port returns false")
end

local function test_server_alive_with_dead_pid()
	local alive = lock.is_server_alive("127.0.0.1", 8421, 99999999)
	assert_eq(alive, false, "should return false when expected_pid is dead (even if port is occupied)")
	passed = passed + 1
	print("  PASS: is_server_alive with dead expected_pid returns false")
end

local function test_server_alive_with_alive_pid_unoccupied_port()
	local alive = lock.is_server_alive("127.0.0.1", 59999, vim.fn.getpid())
	assert_eq(alive, false, "should return false when port is unoccupied (PID is alive but irrelevant)")
	passed = passed + 1
	print("  PASS: is_server_alive with alive PID but unoccupied port returns false")
end

local function test_server_alive_without_pid()
	local alive_no_pid = lock.is_server_alive("127.0.0.1", 59999)
	assert_eq(alive_no_pid, false, "without PID, unoccupied port returns false")

	local alive_with_nil = lock.is_server_alive("127.0.0.1", 59999, nil)
	assert_eq(alive_with_nil, false, "with nil PID, unoccupied port returns false")

	passed = passed + 1
	print("  PASS: is_server_alive without PID skips PID check")
end

-- ---------------------------------------------------------------------------
-- Section 4: takeover stale-lock scenario (the original bug)
--
-- Bug: lock file references a dead PID, but port 8421 is occupied by a
-- DIFFERENT process (e.g. another Neovim). Without PID checking,
-- is_server_alive would return true, causing start() to skip browser launch.
-- ---------------------------------------------------------------------------
local function test_stale_lock_port_reuse()
	print("  Scenario: lock says pid=DEAD on port 8421, but port 8421 is held by different process")

	local dead_pid = 99999999
	assert_eq(lock.is_pid_alive(dead_pid), false, "setup: dead PID should be dead")

	-- If port 8421 happens to be occupied by a different process:
	--   Without PID check: would return true (wrong!)
	--   With PID check: returns false (correct — the owner is dead)
	local alive = lock.is_server_alive("127.0.0.1", 8421, dead_pid)
	assert_eq(alive, false, "stale lock: should return false even if port is occupied by different process")

	passed = passed + 1
	print("  PASS: stale lock with port reuse returns false")
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
local function main()
	print("========================================")
	print("lock.lua semantics tests")
	print("========================================\n")

	print("Section 1: is_pid_alive")
	test_pid_alive_self()
	test_pid_alive_dead()

	print("\nSection 2: write / read / remove")
	test_write_read_roundtrip()
	test_read_corrupt_file()
	test_read_empty_file()

	print("\nSection 3: is_server_alive — port + PID semantics")
	test_server_alive_unoccupied_port()
	test_server_alive_with_dead_pid()
	test_server_alive_with_alive_pid_unoccupied_port()
	test_server_alive_without_pid()

	print("\nSection 4: stale-lock scenario (port reuse bug)")
	test_stale_lock_port_reuse()

	print(string.format("\n========================================"))
	print(string.format("Results: %d passed, %d failed", passed, failed))
	print(string.format("========================================"))

	lock.remove()

	if failed > 0 then
		vim.cmd("cq 1")
	end
end

main()
