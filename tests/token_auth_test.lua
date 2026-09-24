-- tests/token_auth_test.lua
-- End-to-end check that the plugin generates a token, threads it into the
-- served HTML and gates content.md. The suite drives
-- require("markdown_preview").start() directly, not the :MarkdownPreview
-- user command.
--
-- Run: nvim --headless -u NONE -l tests/token_auth_test.lua
-- live-server.nvim is found by tests/helpers.lua ($LIVE_SERVER_RTP,
-- ./live-server-rtp, the checkout's sibling live-server.nvim).

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
-- Where the plugin would write without the helper: the cache Neovim started
-- with (the runner's own under tests/run.sh), and ~/.cache/nvim.
local startup_caches = { vim.fn.stdpath("cache"), vim.fs.normalize("~/.cache/nvim") }
H.isolate()
H.rtp()

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
mp.start()

local ok, eq, http_get = H.ok, H.eq, H.http_get

-- H.isolate raises when stdpath does not follow the variables; what it cannot
-- see is where the plugin writes.
H.section("Section 0: isolation")
local workspace = mp._workspace_dir or ""
ok(vim.startswith(workspace, vim.fn.stdpath("cache") .. "/"), "the plugin's workspace sits under the isolated cache: " .. workspace)
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
ok(r.body:find("data%-live%-token=\"" .. mp._token .. "\"") ~= nil,
	"index.html has data-live-token attribute set to current token")

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
-- status of 0 alone passed (measured). Give the close a moment.
vim.wait(200, function() return false end)
r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.curl_exit, 7, "the port refuses connections after stop")

H.finish()
