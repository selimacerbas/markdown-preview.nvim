-- tests/token_auth_test.lua
-- End-to-end check that :MarkdownPreview generates a token, threads it into
-- the served HTML and gates content.md.
--
-- Run: nvim --headless -u NONE -l tests/token_auth_test.lua
-- live-server.nvim is found by tests/helpers.lua ($LIVE_SERVER_RTP,
-- ./live-server-rtp, ../live-server.nvim).

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
local xdg_root = H.isolate()
H.ok(H.rtp() ~= nil, "live-server.nvim found on one of the three lookup paths")

H.section("Section 0: isolation")
H.ok(vim.fn.stdpath("cache"):find(xdg_root, 1, true) == 1, "stdpath('cache') sits under the temp XDG root")

local tmpdir = H.tmpdir()
local mdfile = vim.fs.joinpath(tmpdir, "test.md")
H.write_file(mdfile, "# hello\n\nbody text here.\n")

vim.cmd("edit " .. vim.fn.fnameescape(mdfile))
vim.bo.filetype = "markdown"

local mp = require("markdown_preview")
-- multi mode so the suite never touches the takeover lock or the shared port
mp.setup({
	open_browser = false,
	instance_mode = "multi",
})

H.section("Section 1: start")
mp.start()

local ok, http_get = H.ok, H.http_get

-- Server instance + token must exist
ok(mp._server_instance ~= nil, "server instance created")
ok(type(mp._token) == "string" and #mp._token == 32, "_token is 32 hex chars")
ok(mp._token:match("^[0-9a-f]+$") ~= nil, "_token is pure hex")

local port = mp._server_instance.port
ok(type(port) == "number" and port > 0, "server bound to a port")

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

H.section("Section 2: stop and verify cleanup")
mp.stop()
ok(mp._token == nil, "_token cleared after stop")
ok(mp._server_instance == nil, "_server_instance cleared after stop")

-- Port no longer accepts connections (give it a moment)
vim.wait(200, function() return false end)
r = http_get(("http://127.0.0.1:%d/"):format(port))
ok(r.status == 0, "port no longer responds after stop (status=" .. tostring(r.status) .. ")")

H.finish()
