-- tests/asset_route_test.lua
-- The relative-image promise of v1.10.0 rides on live-server's asset route.
-- The suite passed against live-server v1.4.0, which has no such route, so
-- the first check names the feature flag and the rest drive the route.
--
-- Run: nvim --headless -u NONE -l tests/asset_route_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local ls_server = require("live_server.server")

H.section("Section 1: the installed live-server is at or above the floor")
H.ok(type(ls_server.features) == "table" and ls_server.features.asset_route == true,
	"live-server exports features.asset_route (v1.5.0 or newer)")

local dir = H.tmpdir()
H.write_file(dir .. "/pic.png", "PNGDATA")
H.write_file(vim.fs.dirname(dir) .. "/outside.txt", "SECRET")
local md = dir .. "/doc.md"
H.write_file(md, "# pics\n\n![](pic.png)\n")
vim.cmd("edit " .. vim.fn.fnameescape(md))
vim.bo.filetype = "markdown"

local mp = require("markdown_preview")
mp.setup({ open_browser = false, instance_mode = "multi" })
mp.start()

H.section("Section 2: the asset route serves files beside the document")
local base = ("http://127.0.0.1:%d"):format(mp._server_instance.port)
H.eq(H.http_get(base .. "/__live/asset?p=pic.png").status, 401, "asset without the token is 401")
local r = H.http_get(base .. "/__live/asset?p=pic.png&t=" .. mp._token)
H.eq(r.status, 200, "asset with the token is 200")
H.eq(r.body, "PNGDATA", "asset body is the file beside the document")
H.eq(H.http_get(base .. "/__live/asset?p=../outside.txt&t=" .. mp._token).status, 404,
	"a path above the document's directory is 404")

mp.stop()
H.finish()
