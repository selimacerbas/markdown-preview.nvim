-- lua/markdown_preview/remote.lua
local uv = vim.loop

local M = {}

function M.send_event(host, port, event_type, json_data)
	local tcp = uv.new_tcp()
	local encoded = vim.uri_encode(json_data)
	local req = string.format(
		"GET /__live/inject?event=%s&data=%s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n",
		event_type, encoded, host
	)
	tcp:connect(host, port, function(err)
		if err then pcall(function() tcp:close() end); return end
		tcp:write(req, function()
			pcall(function() tcp:shutdown() end)
			pcall(function() tcp:close() end)
		end)
	end)
end

return M
