-- tests/token_auth_test.lua
-- End-to-end check that the plugin generates a token, threads it into the
-- served HTML and gates content.md, and that the lockfile holding it is
-- private. The suite drives require("markdown_preview").start() directly, not
-- the :MarkdownPreview user command.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/token_auth_test.lua"
-- live-server.nvim is found by tests/helpers.lua ($LIVE_SERVER_RTP,
-- ./live-server-rtp, the checkout's sibling live-server.nvim).

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
-- Where the plugin would write without the helper: the cache Neovim started
-- with (the runner's own under tests/run.sh), and ~/.cache/nvim.
local startup_caches = { vim.fn.stdpath("cache"), vim.fs.normalize("~/.cache/nvim") }
H.isolate()
local ls_dir = H.rtp()

local tmpdir = H.tmpdir()
local mdfile = vim.fs.joinpath(tmpdir, "test.md")
H.write_file(mdfile, "# hello\n\nbody text here.\n")

vim.cmd("edit " .. vim.fn.fnameescape(mdfile))
vim.bo.filetype = "markdown"

local mp = require("markdown_preview")
-- Sections 0 to 2 run multi mode, a server on an OS-assigned port; the lock
-- sections (3 to 5) write it or start takeover themselves, on a free port,
-- never the shared 8421.
mp.setup({
	open_browser = false,
	instance_mode = "multi",
})
mp.start()

local ok, eq, http_get = H.ok, H.eq, H.http_get

-- H.isolate raises when stdpath does not follow the variables; what it cannot
-- see is where the plugin writes.
H.section("Section 0: isolation")
-- joinpath writes / where stdpath keeps Windows's backslashes, so both names
-- are compared canonical: a .. in the workspace resolves through the
-- filesystem before the prefix test (a lexical walk of its parents passed
-- <cache>/../escape, measured), the separator keeps a sibling such as
-- <cache>x out, and case folds where the filesystem folds, as H.same_path's
-- does.
local workspace = mp._workspace_dir or ""
local function sits_under(path, dir)
	local p, d = H.canon(path), H.canon(dir) .. "/"
	if H.fs_folds_case then
		p, d = p:lower(), d:lower()
	end
	return vim.startswith(p, d)
end
ok(
	workspace ~= "" and sits_under(workspace, vim.fn.stdpath("cache")),
	"the plugin's workspace sits under the isolated cache: " .. workspace
)
ok(
	not sits_under(
		vim.fs.joinpath(vim.fn.stdpath("cache"), "..", "escape", "markdown-preview"),
		vim.fn.stdpath("cache")
	),
	"a workspace that climbs out of the cache with .. does not sit under it"
)
ok(
	not sits_under(vim.fn.stdpath("cache") .. "x/markdown-preview", vim.fn.stdpath("cache")),
	"a sibling whose name starts with the cache's does not sit under it"
)
local written = {}
for _, cache in ipairs(startup_caches) do
	local dir = vim.fs.joinpath(cache, "markdown-preview", vim.fs.basename(workspace))
	if vim.fn.isdirectory(dir) == 1 then
		table.insert(written, dir)
	end
end
eq(table.concat(written, ", "), "", "nothing was written under the cache Neovim started with or ~/.cache/nvim")

H.section("Section 1: start")

-- Server instance + token must exist
ok(mp._server_instance ~= nil, "server instance created")
ok(type(mp._token) == "string" and #mp._token == 32, "_token is 32 hex chars")
ok(mp._token:match("^[0-9a-f]+$") ~= nil, "_token is pure hex")

local port = mp._server_instance.port
ok(type(port) == "number" and port > 0, "server bound to a port")

-- Static index reachable without token
local r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.status, 200, "/ (index) is 200 without token")
ok(
	r.body:find('data%-live%-token="' .. mp._token .. '"') ~= nil,
	"index.html has data-live-token attribute set to current token"
)

-- content.md is gated
r = http_get(("http://127.0.0.1:%d/content.md"):format(port))
eq(r.status, 401, "/content.md without token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=wrong"):format(port))
eq(r.status, 401, "/content.md with a wrong token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token))
eq(r.status, 200, "/content.md with correct token is 200")
ok(r.body:find("hello") ~= nil, "/content.md body contains buffer text")

H.section("Section 2: stop and verify cleanup")
mp.stop()
ok(mp._token == nil, "_token cleared after stop")
ok(mp._server_instance == nil, "_server_instance cleared after stop")

-- Refused is curl 7; a socket left bound and silent is curl 28, which a
-- status of 0 alone passed (measured). Give the close a moment. The first
-- hosted Windows run read 28 here, taken as its two-second retry of a
-- refused loopback connect, which H.http_get's connect bound now waits out;
-- the hosted Windows runs since read 7 there (measured).
vim.wait(200, function()
	return false
end)
r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.curl_exit, 7, "the port refuses connections after stop")

H.section("Section 3: the lockfile keeps the token private")
-- The lockfile carries the session token and the README promises 0600, but
-- the open's mode applies only when it creates the file, so a direct write
-- over a 0644 file kept that mode (measured) until lock.write made it
-- private before writing the token.
local uv = vim.uv
local lock = require("markdown_preview.lock")
local lock_file = vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")
local function mode()
	local stat = uv.fs_stat(lock_file)
	return stat and ("%o"):format(stat.mode % 512) or "missing"
end
if vim.fn.has("win32") == 1 then
	H.skip("a fresh lockfile is 0600 (no POSIX mode bits on Windows)")
	H.skip("a 0644 lockfile is 0600 after lock.write (no POSIX mode bits on Windows)")
else
	lock.remove()
	lock.write(1234, "/w", "TOKEN")
	eq(mode(), "600", "a fresh lockfile is 0600")
	uv.fs_chmod(lock_file, 420)
	lock.write(1234, "/w", "TOKEN")
	eq(mode(), "600", "a 0644 lockfile is 0600 after lock.write")
	lock.remove()
end

-- A port free a moment ago: the takeover port is 8421 unless cfg.port names
-- one (measured in effective_port), and a fixed port would collide with a
-- preview the developer has open.
local function free_port()
	local probe = uv.new_tcp()
	probe:bind("127.0.0.1", 0)
	local p = probe:getsockname().port
	probe:close()
	return p
end
local function read_lock()
	local fd = uv.fs_open(lock_file, "r", 420)
	if not fd then
		return nil
	end
	local data = uv.fs_read(fd, uv.fs_fstat(fd).size, 0)
	uv.fs_close(fd)
	local decoded, tbl = pcall(vim.json.decode, data or "")
	return decoded and tbl or nil
end

H.section("Section 4: the default takeover mode, end to end")
-- Every other start in the suites runs multi, so the default path (the lock
-- election, the lock with the token, a second instance adopting the
-- primary, stop removing the lock) met no gate.
local tport = free_port()
-- The suite's first setup chose multi, and setup merges into the current
-- configuration, so takeover is named here; the second instance below
-- starts from the defaults.
mp.setup({ open_browser = false, instance_mode = "takeover", port = tport })
mp.start()
eq(mp._is_primary, true, "the first takeover start is the primary")
local tinst_port = mp._server_instance and mp._server_instance.port
eq(tinst_port, tport, "the primary serves the configured port")
local held = read_lock()
ok(
	held ~= nil and held.port == tport and held.token == mp._token and held.pid == vim.fn.getpid(),
	"the lock names the port, the session token and this process: " .. vim.inspect(held)
)
if vim.fn.has("win32") == 1 then
	H.skip("the takeover lock is 0600 (no POSIX mode bits on Windows)")
else
	eq(mode(), "600", "the takeover lock is 0600")
end
r = http_get(("http://127.0.0.1:%d/?t=%s"):format(tport, mp._token or ""))
eq(r.status, 200, "the primary answers the tokenized index")
r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(tport, mp._token or ""))
ok(r.status == 200 and r.body:find("hello", 1, true) ~= nil, "the primary serves the buffer with the token")
-- A second Neovim takes the secondary path: the lock's server answers, so
-- it adopts the primary's port and token instead of starting a server.
local second = vim.fs.joinpath(H.tmpdir(), "second.lua")
H.write_file(
	second,
	([[
vim.opt.runtimepath:prepend(%q)
vim.opt.runtimepath:prepend(%q)
local mp = require("markdown_preview")
mp.setup({ open_browser = false, port = %d })
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.bo.filetype = "markdown"
mp.start()
io.stdout:write(vim.json.encode({ primary = mp._is_primary, port = mp._takeover_port, token = mp._token, server = mp._server_instance ~= nil }) .. "\n")
mp.stop()
vim.cmd("qa!")
]]):format(ls_dir, H.root, tport, mdfile)
)
local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", second }, { timeout = 30000 }):wait()
local adopted = (child.stdout or ""):match("({.-})%s*$")
local seen = adopted and select(2, pcall(vim.json.decode, adopted)) or nil
ok(
	type(seen) == "table"
		and seen.primary == false
		and seen.port == tport
		and seen.token == mp._token
		and seen.server == false,
	"a second instance adopts the primary's port and token: "
		.. vim.inspect(seen or ((child.stdout or "") .. (child.stderr or "")))
)
ok(read_lock() ~= nil, "a secondary's stop leaves the primary's lock")
mp.stop()
ok(uv.fs_stat(lock_file) == nil, "the primary's stop removes the lock")

H.section("Section 5: a lock that cannot be made private stops the start")
-- lock.write refuses a file it cannot make private; the refusal came after
-- the server was up, which left it listening with an empty lock, a raw
-- Lua error and no browser.
local fport = free_port()
local real_fchmod = uv.fs_fchmod
uv.fs_fchmod = function()
	return nil, "EPERM: operation not permitted (stubbed)"
end
mp.setup({ open_browser = false, instance_mode = "takeover", port = fport })
local raised, raise_err
local notified = H.expect_error(
	"failed to start server (port " .. fport .. "): cannot make the lock file private",
	function()
		local done, err = pcall(mp.start)
		raised, raise_err = not done, err
	end
)
uv.fs_fchmod = real_fchmod
eq(raised and ("raised: " .. tostring(raise_err)) or "returned", "returned", "start() returns instead of raising")
ok(notified, "the start-failure notification names the port and the reason")
eq(mp._server_instance, nil, "no server instance is kept")
r = http_get(("http://127.0.0.1:%d/"):format(fport))
eq(r.curl_exit, 7, "the port refuses connections: no server is left")
ok(uv.fs_stat(lock_file) == nil, "no lock is left")
mp.stop()

H.finish()
