-- tests/floor_guard_test.lua
-- Below Neovim 0.10 every documented command is a refuser that answers each
-- use with the floor module's text and the module answers a config's
-- setup() without loading the plugin or live-server (one ERROR notification
-- at load between them), unless the config opted out; on a supported
-- version the commands are defined.
--
-- Run: nvim --headless -u NONE -l tests/floor_guard_test.lua
-- live-server.nvim is found by tests/helpers.lua ($LIVE_SERVER_RTP,
-- ./live-server-rtp, the checkout's sibling live-server.nvim).
local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()
local plugin_file = H.root .. "/plugin/markdown-preview.lua"
-- The plugin's entry module, the prefix its commands share and the features
-- its floor module tests beside the version.
local MODULE = "markdown_preview"
local COMMAND_PREFIX = "MarkdownPreview"
local FEATURES = { "uv", "fs.joinpath", "uri_encode" }

-- The documented commands: the README's command table, sorted.
local documented = {}
for line in io.lines(H.root .. "/README.md") do
	local name = line:match("^| `:(%w+)`")
	if name then
		table.insert(documented, name)
	end
end
table.sort(documented)
documented = table.concat(documented, " ")

-- The plugin's commands Neovim has, by the shared prefix, sorted: a set
-- equal to the README's is every documented command and no other.
local function defined()
	local names = {}
	for name in pairs(vim.api.nvim_get_commands({})) do
		if vim.startswith(name, COMMAND_PREFIX) then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return table.concat(names, " ")
end

-- A loaded module of this plugin or of live-server besides the entry module
-- and the floor module is code that needs 0.10.
local function loaded_below()
	local found = {}
	for name in pairs(package.loaded) do
		local plugin = name == MODULE or vim.startswith(name, MODULE .. ".")
		local ls = name == "live_server" or vim.startswith(name, "live_server.")
		if (plugin or ls) and name ~= MODULE and name ~= MODULE .. ".floor" then
			table.insert(found, name)
		end
	end
	table.sort(found)
	return table.concat(found, ", ")
end

-- The floor module's verdict, its chunk run against a vim that lacks field
-- (a dotted name; nil hides nothing), since a field removed from the running
-- vim can come back through its lazy loader (vim.uri_encode does, measured).
local function floor_ok_without(field)
	local chunk = assert(loadfile(H.root .. "/lua/" .. MODULE .. "/floor.lua"))
	local function proxy(real, prefix)
		return setmetatable({}, {
			__index = function(_, key)
				local name = prefix .. key
				if name == field then
					return nil
				end
				local value = real[key]
				if type(value) == "table" and field and vim.startswith(field, name .. ".") then
					return proxy(value, name .. ".")
				end
				return value
			end,
		})
	end
	setfenv(chunk, setmetatable({ vim = proxy(vim, "") }, { __index = _G }))
	return chunk().ok
end

-- The guard's return comes before every require but the floor module's, in
-- the source, so a require moved above it reds even when the module it
-- loads happens to need nothing newer.
local function guard_precedes_requires()
	local src = table.concat(vim.fn.readfile(H.root .. "/lua/" .. MODULE .. "/init.lua"), "\n")
	src = src:gsub("%-%-[^\n]*", "")
	local guard = src:find("if not floor.ok then", 1, true)
	local ret = guard and src:find("return setmetatable", guard, true)
	local first
	for at, name in src:gmatch("()require%s*%(?%s*[\"']([^\"']+)[\"']") do
		if name ~= MODULE .. ".floor" then
			first = at
			break
		end
	end
	return guard ~= nil and ret ~= nil and (first == nil or ret < first),
		("guard at %s, its return at %s, the first other require at %s"):format(guard, ret, first)
end

-- Every refusal is recorded, notify_once's own dedupe aside, so the plugin
-- file's and the module's are checked apart; a refuser's goes through
-- vim.notify, since each use answers.
local notices, refusals = {}, {}
local real_once, real_notify = vim.notify_once, vim.notify
vim.notify_once = function(msg, level)
	notices[#notices + 1] = { msg = msg, level = level }
end
vim.notify = function(msg, level)
	refusals[#refusals + 1] = { msg = msg, level = level }
end
local real_has = vim.fn.has
vim.fn.has = function(feature)
	if feature == "nvim-0.10" then
		return 0
	end
	return real_has(feature)
end
local function turn_loop()
	vim.wait(50, function()
		return false
	end)
end

H.section("Section 1: below the floor")
H.ok(documented ~= "", "the README's command table lists the commands: " .. documented)
-- A config that sets the load guard has opted out, and an old-Neovim host
-- that shares the config must not be told at every start.
vim.g.loaded_markdown_preview = 1
vim.cmd("source " .. vim.fn.fnameescape(plugin_file))
turn_loop()
H.eq(
	("%d notices, commands %q"):format(#notices + #refusals, defined()),
	'0 notices, commands ""',
	"a config that opted out hears nothing below the floor"
)
vim.g.loaded_markdown_preview = nil
vim.cmd("source " .. vim.fn.fnameescape(plugin_file))
local message = require(MODULE .. ".floor").message
H.ok(message:find("0.10", 1, true) ~= nil, "the floor text names the floor")
-- lazy.nvim's cmd and keys specs run the command they were given, so each
-- documented one exists below the floor to say why.
H.eq(defined(), documented, "every documented command is defined below the floor, and no other")
-- lazy.nvim sources plugin files with :source, where an ERROR notification
-- on 0.9 raised a Vim(source) exception, so the refusal waits for the source
-- to return and shows once the loop turns.
H.eq(#notices, 0, "the plugin file's refusal waits until the :source returns")
vim.wait(1000, function()
	return #notices > 0
end)
H.eq(#notices, 1, "the plugin file refuses with one notification")
-- A refusal that set the load guard would keep a later source on a
-- supported Neovim from defining the commands.
H.eq(vim.g.loaded_markdown_preview, nil, "a refused load leaves the load guard unset")
-- A cmd spec runs the command through vim.cmd inside lazy.nvim's handler,
-- where an ERROR notification on 0.9 raised a traceback, so a refuser's waits
-- too; every use answers, a second one included.
local names = vim.split(documented, " ")
-- Under pcall, so a command that is missing reds its own rows below and not
-- the whole suite.
for _, name in ipairs(names) do
	pcall(vim.cmd, name)
end
H.eq(#refusals, 0, "a refuser's answer waits until the command returns")
pcall(vim.cmd, names[1])
turn_loop()
H.eq(#refusals, #names + 1, "every documented command answers each use below the floor")
local refused_right = #refusals > 0
for _, refusal in ipairs(refusals) do
	refused_right = refused_right and refusal.msg == message and refusal.level == vim.log.levels.ERROR
end
H.ok(refused_right, "every refuser answers with the floor text as an ERROR")
-- lazy.nvim's config calls setup() whatever the plugin file did.
package.loaded[MODULE] = nil
local setup_ok, setup_err = pcall(function()
	require(MODULE).setup({})
end)
H.ok(setup_ok, "setup() raises nothing below the floor" .. (setup_ok and "" or (": " .. tostring(setup_err))))
H.eq(loaded_below(), "", "the module returns before any module but the floor module loads")
local structural, where = guard_precedes_requires()
H.ok(structural, "the module's floor guard returns before its first require but the floor module's: " .. where)
-- A lazy load on FileType runs the module inside 0.9's filetype nvim_cmd,
-- where an ERROR notification raised Vim(append), so this refusal waits too.
H.eq(#notices, 1, "the module's refusal waits until the require returns")
vim.wait(1000, function()
	return #notices > 1
end)
H.eq(#notices, 2, "the module refuses with one notification too")
-- Any field a config calls answers an empty string, never a nil.
local other_ok, other = pcall(function()
	return require(MODULE).anything_else()
end)
H.eq(
	other_ok and tostring(other) or ("raised " .. tostring(other)),
	"",
	"an undocumented field on the stub answers the same"
)
-- notify_once shows a text once, so the floor module's text in both
-- refusals is one notification on screen, whichever of them runs first.
local all_floor_text, all_errors = #notices > 0, #notices > 0
for _, notice in ipairs(notices) do
	all_floor_text = all_floor_text and notice.msg == message
	all_errors = all_errors and notice.level == vim.log.levels.ERROR
end
H.ok(all_floor_text, "both refusals are the floor module's text, so the user sees one notification")
H.ok(all_errors, "every refusal is an ERROR")
-- notify_once arrived in 0.7 and a Lua plugin file is sourced from 0.5 on,
-- so without it each guard shows the text through vim.notify, once.
vim.notify_once = nil
refusals = {}
for name in pairs(package.loaded) do
	if name == MODULE or vim.startswith(name, MODULE .. ".") then
		package.loaded[name] = nil
	end
end
vim.cmd("source " .. vim.fn.fnameescape(plugin_file))
turn_loop()
H.eq(
	#refusals == 1 and refusals[1].msg or #refusals,
	message,
	"without notify_once the plugin file shows the text once"
)
require(MODULE).setup({})
turn_loop()
H.eq(#refusals == 2 and refusals[2].msg or #refusals, message, "without notify_once the module shows the text once")

H.section("Section 2: at the floor")
vim.fn.has = real_has
vim.notify_once = real_once
vim.notify = real_notify
vim.g.loaded_markdown_preview = nil
-- The refusers go, so every command counted below is the real plugin's.
for _, name in ipairs(names) do
	pcall(vim.api.nvim_del_user_command, name)
end
-- The stub and the floor module's verdict go with every other module of
-- this plugin and live-server's, and so does the sentinel require leaves for
-- a module that raised while loading.
for name in pairs(package.loaded) do
	local plugin = name == MODULE or vim.startswith(name, MODULE .. ".")
	if plugin or name == "live_server" or vim.startswith(name, "live_server.") then
		package.loaded[name] = nil
	end
end
H.ok(floor_ok_without(nil), "the floor admits this Neovim")
for _, field in ipairs(FEATURES) do
	H.eq(floor_ok_without(field), false, "the floor refuses a Neovim without vim." .. field .. ", whatever its version")
end
vim.cmd("source " .. vim.fn.fnameescape(plugin_file))
-- By type: a left-over stub answers config with a function.
H.ok(
	type(require(MODULE).config) == "table" and type(package.loaded["live_server.server"]) == "table",
	"the plugin's own modules and live-server's load on a supported Neovim"
)
H.eq(defined(), documented, "every documented command is defined on a supported Neovim, and no other")
H.finish()
