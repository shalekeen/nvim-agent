-- Integration test for nvim-agent's pure-Lua surface.
-- Run with: nvim -l tests/integration_test.lua
--
-- Exits with status 1 if any check fails. Designed to be runnable from a
-- fresh checkout without needing the user's full nvim config; deps that the
-- plugin pcall'd into (which-key, barbar) are stubbed via package.preload.

-- ---------------------------------------------------------------------------
-- Bootstrapping: locate this script so we can resolve sibling paths reliably.
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
-- Trim trailing slash, then strip the final "/tests" component to get repo root.
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

package.path = plugin_root .. "/lua/?.lua;"
	.. plugin_root .. "/lua/?/init.lua;"
	.. package.path

-- Add the plugin to runtimepath so vim.api.nvim_get_runtime_file() can resolve
-- mcp/server.lua during the claude_code adapter setup. Without this the
-- adapter's MCP wiring warns that the script is missing — same warning a real
-- user would see if their plugin manager forgot to add the plugin to rtp.
vim.opt.runtimepath:append(plugin_root)

-- Stub the hard deps so M.setup() passes its dependency checks. We're not
-- exercising keymaps/bufferline behaviour in this test — only Lua APIs.
package.preload["which-key"] = function()
	return { add = function() end, register = function() end }
end
package.preload["barbar"] = function()
	return {}
end
package.preload["barbar.state"] = function()
	return nil
end
package.preload["barbar.ui.render"] = function()
	return nil
end

-- ---------------------------------------------------------------------------
-- Tiny test harness.
-- ---------------------------------------------------------------------------

local fail_count = 0
local total = 0

local function check(label, ok, detail)
	total = total + 1
	if ok then
		print("PASS " .. label)
	else
		print("FAIL " .. label .. (detail and (" — " .. detail) or ""))
		fail_count = fail_count + 1
	end
end

local function assert_eq(label, actual, expected)
	check(label, actual == expected, string.format("expected %q, got %q", tostring(expected), tostring(actual)))
end

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- 1. config.setup merges opts over defaults.
-- ---------------------------------------------------------------------------

local config = require("nvim-agent.config")
config.setup({ adapter = "claude_code", auto_open = true })
local cfg = config.get()
assert_eq("config.setup applies adapter", cfg.adapter, "claude_code")
assert_eq("config.setup applies auto_open", cfg.auto_open, true)
assert_eq("config.setup keeps default base_dir", cfg.base_dir, vim.fn.expand("~/.nvim-agent"))
check(
	"config.setup keeps default agent_instruction_header",
	type(cfg.agent_instruction_header) == "string" and cfg.agent_instruction_header:find("nvim%-agent") ~= nil,
	"header missing or doesn't mention nvim-agent"
)

-- ---------------------------------------------------------------------------
-- 2. context.get_agent_preamble — verifies agent_instruction_header always
--    appended after the base (the change made for the dead-code fix).
-- ---------------------------------------------------------------------------

local context = require("nvim-agent.context")

-- Reset to a known config so we can assert on exact substrings.
config.setup({
	default_system_prompt = "BASE_PROMPT",
	agent_instruction_header = "HEADER_TEXT",
})

local p_default = context.get_agent_preamble()
assert_eq("preamble: no base falls back to default + header", p_default, "BASE_PROMPT\n\nHEADER_TEXT")

local p_custom = context.get_agent_preamble("CUSTOM_BASE")
assert_eq("preamble: custom base + header", p_custom, "CUSTOM_BASE\n\nHEADER_TEXT")

local p_empty_base = context.get_agent_preamble("")
assert_eq("preamble: empty base yields header alone", p_empty_base, "HEADER_TEXT")

-- With no header configured, just the base.
config.setup({ default_system_prompt = "ONLY_BASE", agent_instruction_header = "" })
local p_no_header = context.get_agent_preamble()
assert_eq("preamble: empty header yields base alone", p_no_header, "ONLY_BASE")

-- ---------------------------------------------------------------------------
-- 3. flavor.list() filters reserved names — covers the agent_templates fix.
-- ---------------------------------------------------------------------------

local tmp_base = vim.fn.tempname()
vim.fn.mkdir(tmp_base, "p")
config.setup({ base_dir = tmp_base })

-- Reserved (must not appear in flavor list)
for _, name in ipairs({ "active", "sessions", "hooks", "agent_templates" }) do
	vim.fn.mkdir(tmp_base .. "/" .. name, "p")
end
-- Real flavors
for _, name in ipairs({ "dev", "review", "exploratory" }) do
	vim.fn.mkdir(tmp_base .. "/" .. name, "p")
end
-- Hidden dir (must be skipped by the dotfile filter)
vim.fn.mkdir(tmp_base .. "/.cache", "p")
-- Stray file (must be skipped by the isdirectory filter)
do
	local f = io.open(tmp_base .. "/last_flavor.json", "w")
	f:write("{}")
	f:close()
end

local flavor = require("nvim-agent.flavor")
local listed = flavor.list()
table.sort(listed)

check("flavor.list returns exactly the real flavor dirs", #listed == 3, "got " .. #listed .. " entries")
assert_eq("flavor.list[1] = dev", listed[1], "dev")
assert_eq("flavor.list[2] = exploratory", listed[2], "exploratory")
assert_eq("flavor.list[3] = review", listed[3], "review")

for _, reserved in ipairs({ "active", "sessions", "hooks", "agent_templates" }) do
	check(
		"flavor.list excludes reserved name '" .. reserved .. "'",
		not contains(listed, reserved),
		"'" .. reserved .. "' leaked into the flavor list"
	)
end
check("flavor.list excludes dotfile dirs", not contains(listed, ".cache"))
check("flavor.list excludes plain files", not contains(listed, "last_flavor.json"))

-- Cleanup
vim.fn.delete(tmp_base, "rf")

-- ---------------------------------------------------------------------------
-- 4. flavor.create seeds the expected files (covers default_system_prompt
--    being written into a new flavor's system_prompt.md, which is the basis
--    of the README's "default_system_prompt seeded into new flavors" claim).
-- ---------------------------------------------------------------------------

local tmp_base2 = vim.fn.tempname()
vim.fn.mkdir(tmp_base2, "p")
config.setup({ base_dir = tmp_base2, default_system_prompt = "SEED_PROMPT" })

flavor.create("test_flavor")
local flavor_dir = tmp_base2 .. "/test_flavor"

local function read(p)
	local f = io.open(p, "r")
	if not f then
		return nil
	end
	local c = f:read("*a")
	f:close()
	return c
end

assert_eq("flavor.create seeds system_prompt.md with default", read(flavor_dir .. "/system_prompt.md"), "SEED_PROMPT")
check(
	"flavor.create seeds non-empty user_notes.md",
	(read(flavor_dir .. "/user_notes.md") or ""):find("User Notes") ~= nil
)
assert_eq("flavor.create seeds persistent_dirs.json with []", read(flavor_dir .. "/persistent_dirs.json"), "[]")

vim.fn.delete(tmp_base2, "rf")

-- ---------------------------------------------------------------------------
-- 5. mcp/server.lua resolves on the runtimepath. This is what
--    claude_code.lua relies on to spawn the MCP server, regardless of how
--    the user installed the plugin (lazy, packer, manual, …).
-- ---------------------------------------------------------------------------

local resolved = vim.api.nvim_get_runtime_file("lua/nvim-agent/mcp/server.lua", false)
check(
	"runtime_file resolves mcp/server.lua",
	#resolved >= 1 and resolved[1]:match("/mcp/server%.lua$") ~= nil,
	"got: " .. vim.inspect(resolved)
)

-- ---------------------------------------------------------------------------
-- 6. M.setup hard-dep checks: requires which-key and barbar.
-- ---------------------------------------------------------------------------

-- We've already loaded the plugin once with stubs in place, so calling
-- M.setup again with the stubs should succeed. That's the positive case.
package.loaded["nvim-agent"] = nil
local ok_setup, err_setup = pcall(function()
	require("nvim-agent").setup({ adapter = "claude_code" })
end)
check("setup() succeeds when which-key + barbar are present", ok_setup, err_setup)

-- Negative case: drop the barbar stub and confirm setup errors with a
-- recognisable message.
package.preload["barbar"] = nil
package.loaded["barbar"] = nil
package.loaded["nvim-agent"] = nil
local ok_no_barbar, err_no_barbar = pcall(function()
	require("nvim-agent").setup({ adapter = "claude_code" })
end)
check(
	"setup() errors when barbar is missing",
	(not ok_no_barbar) and tostring(err_no_barbar):find("barbar%.nvim is required") ~= nil,
	"expected barbar-required error, got: " .. tostring(err_no_barbar)
)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
