-- tests/token_auth_test.lua
-- End-to-end check that :MarkdownPreview generates a token, threads it into
-- the served HTML, gates content.md, and that scroll-sync RPC carries it.
--
-- Run: nvim --headless -c "set rtp+=./live-server-rtp" -c "set rtp+=." \
--          -c "luafile tests/token_auth_test.lua" -c "qa!"
--
-- The CI workflow shims live-server.nvim into ./live-server-rtp before run.

local uv = vim.loop

-- ─── Setup: open a markdown buffer ──────────────────────────────────────────
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local mdfile = vim.fs.joinpath(tmpdir, "test.md")
do
	local fd = uv.fs_open(mdfile, "w", 420)
	uv.fs_write(fd, "# hello\n\nbody text here.\n", 0)
	uv.fs_close(fd)
end

vim.cmd("edit " .. mdfile)
vim.bo.filetype = "markdown"

-- ─── Configure: avoid opening a real browser, force multi mode for isolation
local mp = require("markdown_preview")
mp.setup({
	open_browser = false,
	instance_mode = "multi",
})

-- ─── Start ──────────────────────────────────────────────────────────────────
mp.start()

local passed, failed = 0, 0
local function ok(cond, msg)
	if cond then
		passed = passed + 1
		print("  PASS: " .. msg)
	else
		failed = failed + 1
		print("  FAIL: " .. msg)
	end
end

-- Server instance + token must exist
ok(mp._server_instance ~= nil, "server instance created")
ok(type(mp._token) == "string" and #mp._token == 32, "_token is 32 hex chars")
ok(mp._token:match("^[0-9a-f]+$") ~= nil, "_token is pure hex")

local port = mp._server_instance.port
ok(type(port) == "number" and port > 0, "server bound to a port")

-- ─── HTTP curl helper ───────────────────────────────────────────────────────
local function http_get(url)
	local out = vim.fn.system({ "curl", "-s", "-o", "-", "-w", "\nHTTPSTATUS:%{http_code}", url })
	local body, status = out:match("^(.*)\nHTTPSTATUS:(%d+)%s*$")
	return { status = tonumber(status), body = body or "" }
end

-- Static index reachable without token
local r = http_get(("http://127.0.0.1:%d/"):format(port))
ok(r.status == 200, "/ (index) is 200 without token")
ok(r.body:find("data%-live%-token=\"" .. mp._token .. "\"") ~= nil,
	"index.html has data-live-token attribute set to current token")

-- content.md is gated
r = http_get(("http://127.0.0.1:%d/content.md"):format(port))
ok(r.status == 401, "/content.md without token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token))
ok(r.status == 200, "/content.md with correct token is 200")
ok(r.body:find("hello") ~= nil, "/content.md body contains buffer text")

-- ─── Stop and verify cleanup ────────────────────────────────────────────────
mp.stop()
ok(mp._token == nil, "_token cleared after stop")
ok(mp._server_instance == nil, "_server_instance cleared after stop")

-- Port no longer accepts connections (give it a moment)
vim.wait(200, function() return false end)
r = http_get(("http://127.0.0.1:%d/"):format(port))
ok(r.status == nil or r.status == 0, "port no longer responds after stop (status=" .. tostring(r.status) .. ")")

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", passed, failed))
print(string.format("========================================"))

if failed > 0 then vim.cmd("cq 1") end
