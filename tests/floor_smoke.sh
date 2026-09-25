#!/bin/sh
# The refusal a Neovim below the floor meets, run on such a Neovim (CI's
# floor-below job runs 0.9.5; locally, put one first on PATH). The suites
# cannot run there (the helper needs 0.10), and floor_guard mocks has() on a
# supported Neovim, which passes a 0.10 API reached before a guard that a
# real 0.9.5 raises on (measured); no helper is loaded here for that reason.
#
# The plugin file is sourced as Neovim's own loading sources it (:runtime),
# and the check then reads what the user meets: the floor text once in
# :messages and no traceback, every command the README's table documents
# defined and answering a use with the text again, setup() returning, a
# stub field answering an empty string, and no module but the entry and
# floor modules loaded, live-server's included (./live-server-rtp joins the
# runtimepath when it exists, as the suites find it). The XDG directories
# point at a private directory, as tests/run.sh does, so a start package
# cannot answer for the checkout.
set -u
cd "$(dirname "$0")/.." || exit 1
set -- plugin/*.lua
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "floor_smoke: expected one plugin/*.lua, found: $*" >&2
    exit 1
fi
plugin_file=$1
set -- lua/*/init.lua
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "floor_smoke: expected one lua/<module>/init.lua, found: $*" >&2
    exit 1
fi
module=${1#lua/}
module=${module%/init.lua}
# The backticks are the README's Markdown, matched literally.
# shellcheck disable=SC2016
commands=$(sed -n 's/^| `:\([A-Za-z0-9_]*\)`.*/\1/p' README.md | tr '\n' ' ')
if [ -z "$commands" ]; then
    echo "floor_smoke: README.md's command table lists no command" >&2
    exit 1
fi
rtp=$PWD
[ -d live-server-rtp ] && rtp="$rtp,$PWD/live-server-rtp"
run=$(mktemp -d) || exit 1
trap 'rm -rf "$run"' EXIT
cat >"$run/check.lua" <<'LUA'
local module = os.getenv("SMOKE_MODULE")
local fails = 0
-- An error message holds its line open until the next message begins, so an
-- empty echo ends it before a line of this check starts.
local function check(cond, what)
    pcall(vim.api.nvim_echo, { { "" } }, false, {})
    io.stdout:write((cond and "ok: " or "FAIL: ") .. what .. "\n")
    if not cond then
        fails = fails + 1
    end
end
local function turn_loop()
    vim.wait(200, function()
        return false
    end)
end
local found, floor = pcall(require, module .. ".floor")
local message = found and type(floor) == "table" and floor.message or nil
check(type(message) == "string" and message:find("requires Neovim 0.10", 1, true) ~= nil,
    "the floor module states the floor: " .. tostring(message))
message = message or "(no floor text)"
local function shown()
    local log, count, from = vim.fn.execute("messages"), 0, 1
    while true do
        local _, stop = log:find(message, from, true)
        if not stop then
            return count, log
        end
        count, from = count + 1, stop + 1
    end
end
-- On a supported Neovim the commands are the real ones, and one waits for
-- input, so the check stops here.
if vim.fn.has("nvim-0.10") == 1 then
    check(false, "this Neovim is below the floor: it is 0.10 or newer")
    vim.cmd("cq 1")
end
turn_loop()
check(shown() == 1, "loading the plugin shows the floor text once (" .. shown() .. ")")
local names = {}
for name in os.getenv("SMOKE_COMMANDS"):gmatch("%S+") do
    names[#names + 1] = name
    check(vim.fn.exists(":" .. name) == 2, ":" .. name .. " is defined")
end
local ran, err = pcall(vim.cmd, names[1])
check(ran, ":" .. names[1] .. " runs without raising" .. (ran and "" or (": " .. tostring(err))))
turn_loop()
check(shown() == 2, "a use of :" .. names[1] .. " shows the floor text again (" .. shown() .. ")")
local set_up, set_err = pcall(function()
    return require(module).setup({})
end)
check(set_up, "setup() returns" .. (set_up and "" or (": " .. tostring(set_err))))
local field_ok, field = pcall(function()
    return require(module).statusline()
end)
check(field_ok and field == "", "a stub field answers an empty string: " .. tostring(field))
turn_loop()
local loaded = {}
for name in pairs(package.loaded) do
    local ours = name == module or name:sub(1, #module + 1) == module .. "."
    local ls = name == "live_server" or name:sub(1, 12) == "live_server."
    if (ours or ls) and name ~= module and name ~= module .. ".floor" then
        loaded[#loaded + 1] = name
    end
end
check(#loaded == 0, "no module that needs 0.10 loaded: " .. table.concat(loaded, ", "))
local count, log = shown()
check(count == 2, "setup() adds no second notification (" .. count .. ")")
check(not log:find("traceback", 1, true), "no traceback in :messages")
io.stdout:write("floor smoke: " .. (fails == 0 and "pass" or (fails .. " failed")) .. "\n")
io.stdout:flush()
vim.cmd(fails == 0 and "qa!" or "cq 1")
LUA
XDG_CONFIG_HOME=$run/config XDG_DATA_HOME=$run/data XDG_STATE_HOME=$run/state XDG_CACHE_HOME=$run/cache \
    SMOKE_RTP=$rtp SMOKE_MODULE=$module SMOKE_COMMANDS=$commands \
    nvim --headless -u NONE \
    --cmd 'lua vim.o.runtimepath = os.getenv("SMOKE_RTP") .. "," .. vim.o.runtimepath' \
    -c "runtime $plugin_file" \
    -c "luafile $run/check.lua" \
    -c 'cq 2'
