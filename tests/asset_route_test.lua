-- tests/asset_route_test.lua
-- The relative-image promise of v1.10.0 rides on live-server's asset route.
-- The suite passed against live-server v1.4.0, which has no such route, so
-- the first check names the feature flag and the rest drive the route; the
-- plugin's asset_root sidecar, which names the document's directory, stays
-- behind the token.
--
-- Run: nvim --headless -u NONE -l tests/asset_route_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local uv = vim.uv

local ls_server = require("live_server.server")

H.section("Section 1: the installed live-server is at or above the floor")
H.ok(
	type(ls_server.features) == "table" and ls_server.features.asset_route == true,
	("live-server exports features.asset_route (%s or newer)"):format(H.live_server_floor)
)

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
H.eq(H.http_get(base .. "/__live/asset?p=pic.png&t=wrong").status, 401, "asset with a wrong token is 401")
local r = H.http_get(base .. "/__live/asset?p=pic.png&t=" .. mp._token)
H.eq(r.status, 200, "asset with the token is 200")
H.eq(r.body, "PNGDATA", "asset body is the file beside the document")
H.eq(
	H.http_get(base .. "/__live/asset?p=../outside.txt&t=" .. mp._token).status,
	404,
	"a path above the document's directory is 404"
)
-- Containment is by the resolved path, not the spelling: a lexical check
-- served a link like this one (measured on a live-server mutant). The
-- target is written with the platform's separator, since Windows took a /
-- in it unconverted and the link did not resolve (measured on the hosted
-- runner); a link that cannot be made or does not resolve proves nothing
-- and is skipped, counted.
local linked, link_err = uv.fs_symlink(".." .. package.config:sub(1, 1) .. "outside.txt", dir .. "/link.txt")
if linked and uv.fs_stat(dir .. "/link.txt") then
	H.eq(
		H.http_get(base .. "/__live/asset?p=link.txt&t=" .. mp._token).status,
		404,
		"a symlink beside the document pointing above it is 404"
	)
else
	H.skip(
		"a symlink beside the document pointing above it is 404 ("
			.. tostring(link_err or "the link does not resolve")
			.. ")"
	)
end

H.section("Section 3: the asset_root sidecar is gated")
-- Ungated, it hands any client the document's absolute directory (measured).
H.eq(H.http_get(base .. "/asset_root").status, 401, "the asset_root sidecar without the token is 401")

mp.stop()
H.finish()
