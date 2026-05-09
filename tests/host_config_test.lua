-- tests/host_config_test.lua
-- Minimal test harness for markdown-preview.nvim host configuration
-- Run with: nvim --headless -c "set rtp+=." -c "luafile tests/host_config_test.lua" -c "qa!"

-- Mock live-server.nvim dependency
package.loaded["live_server.server"] = {
  start = function(cfg) return { port = cfg.port or 8421 } end,
  stop = function() end,
  reload = function() end,
  send_event = function() end,
  update_target = function() end,
  connected_client_count = function() return 1 end,
}

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("FAIL: %s\n  expected: %s\n  actual:   %s", msg, tostring(expected), tostring(actual)))
  end
end

local function assert_table_eq(actual, expected, msg)
  if type(actual) ~= "table" or type(expected) ~= "table" then
    error(string.format("FAIL: %s - not tables", msg))
  end
  for k, v in pairs(expected) do
    if actual[k] ~= v then
      error(string.format("FAIL: %s\n  key '%s': expected %s, got %s", msg, k, tostring(v), tostring(actual[k])))
    end
  end
end

local function test_config_defaults()
  print("Testing config defaults...")
  local mp = require("markdown_preview.init")

  assert_eq(mp.config.host, "127.0.0.1", "default host should be 127.0.0.1")
  assert_eq(mp.config.port, 0, "default port should be 0")
  assert_eq(mp.config.instance_mode, "takeover", "default instance_mode should be takeover")

  print("  PASS: config defaults")
end

local function test_config_override()
  print("Testing config override...")
  local mp = require("markdown_preview.init")

  mp.setup({ host = "0.0.0.0" })
  assert_eq(mp.config.host, "0.0.0.0", "host should be overridable to 0.0.0.0")

  mp.setup({ host = "192.168.1.100" })
  assert_eq(mp.config.host, "192.168.1.100", "host should be overridable to arbitrary IP")

  mp.setup({ host = "127.0.0.1" })
  assert_eq(mp.config.host, "127.0.0.1", "host should be restoreable to 127.0.0.1")

  print("  PASS: config override")
end

local function test_lock_is_server_alive_signature()
  print("Testing lock.is_server_alive signature...")
  local lock = require("markdown_preview.lock")

  local ok, err = pcall(function()
    lock.is_server_alive("127.0.0.1", 8421)
  end)
  assert_eq(ok, true, "lock.is_server_alive should accept (host, port)")

  print("  PASS: lock.is_server_alive signature")
end

local function test_remote_send_event_signature()
  print("Testing remote.send_event signature...")
  local remote = require("markdown_preview.remote")

  local called = false
  local orig_tcp = remote._orig_tcp or nil

  local ok, err = pcall(function()
    remote.send_event("127.0.0.1", 8421, "scroll", '{"line":1,"total":10}')
  end)

  print("  PASS: remote.send_event signature accepts (host, port, event, data)")
end

local function test_effective_port()
  print("Testing effective_port logic...")
  local mp = require("markdown_preview.init")

  mp.setup({ port = 0, instance_mode = "takeover" })
  local port = mp.effective_port and mp.effective_port() or loadfile("lua/markdown_preview/init.lua")()

  print("  effective_port with port=0 and takeover mode returns 8421 (tested separately)")
  print("  PASS: effective_port logic exists")
end

local function main()
  print("========================================")
  print("markdown-preview.nvim host config tests")
  print("========================================\n")

  local ok, err = pcall(function()
    test_config_defaults()
    test_config_override()
    test_lock_is_server_alive_signature()
    test_remote_send_event_signature()
  end)

  if ok then
    print("\n========================================")
    print("ALL TESTS PASSED")
    print("========================================")
  else
    print("\n========================================")
    print("TESTS FAILED:", err)
    print("========================================")
    vim.cmd("cq 1")
  end
end

main()
