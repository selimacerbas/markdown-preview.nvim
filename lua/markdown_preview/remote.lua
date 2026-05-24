-- lua/markdown_preview/remote.lua
local uv = vim.loop

local M = {}

function M.send_event(host, port, event_type, json_data, token)
	local tcp = uv.new_tcp()
	local encoded = vim.uri_encode(json_data)
	local query = string.format("event=%s&data=%s", event_type, encoded)
	if token and token ~= "" then
		query = query .. "&t=" .. vim.uri_encode(token)
	end
	local req = string.format(
		"GET /__live/inject?%s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n",
		query, host
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
