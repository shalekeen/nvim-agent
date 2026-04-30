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
	"config.setup keeps default nvim_agent_preamble",
	type(cfg.nvim_agent_preamble) == "string" and cfg.nvim_agent_preamble:find("nvim%-agent") ~= nil,
	"preamble missing or doesn't mention nvim-agent"
)

-- ---------------------------------------------------------------------------
-- 2. context.compose_system_prompt — verifies the three-layer composition:
--      1. config.nvim_agent_preamble  (always first)
--      2. <active_dir>/system_prompt.md (or config.default_system_prompt)
--      3. <active_dir>/agent_prompt.md  (omitted when empty/missing)
--    Each non-empty layer is joined by a single blank line.
-- ---------------------------------------------------------------------------

local context = require("nvim-agent.context")

-- Reset to a known config so we can assert on exact substrings.
config.setup({
	default_system_prompt = "BASE_PROMPT",
	nvim_agent_preamble = "PREAMBLE",
})

-- No active_dir → preamble + default_system_prompt only (no layer 3 source).
local p_default = context.compose_system_prompt(nil)
assert_eq("compose: preamble + default (no active_dir)", p_default, "PREAMBLE\n\nBASE_PROMPT")

-- Active dir exists but contains no files → still falls back to default.
local tmp_active = vim.fn.tempname()
vim.fn.mkdir(tmp_active, "p")
local p_empty_dir = context.compose_system_prompt(tmp_active)
assert_eq("compose: empty active dir falls back to default", p_empty_dir, "PREAMBLE\n\nBASE_PROMPT")

-- system_prompt.md present → its content replaces the default for layer 2.
local sp = io.open(tmp_active .. "/system_prompt.md", "w")
sp:write("FLAVOR_PROMPT")
sp:close()
local p_with_sys = context.compose_system_prompt(tmp_active)
assert_eq("compose: system_prompt.md overrides default", p_with_sys, "PREAMBLE\n\nFLAVOR_PROMPT")

-- agent_prompt.md present → appended as layer 3.
local ap = io.open(tmp_active .. "/agent_prompt.md", "w")
ap:write("AGENT_ADDENDUM")
ap:close()
local p_full = context.compose_system_prompt(tmp_active)
assert_eq(
	"compose: all three layers, in order",
	p_full,
	"PREAMBLE\n\nFLAVOR_PROMPT\n\nAGENT_ADDENDUM"
)

-- Empty agent_prompt.md → layer 3 is omitted (no dangling blank line).
io.open(tmp_active .. "/agent_prompt.md", "w"):close()
local p_empty_agent = context.compose_system_prompt(tmp_active)
assert_eq(
	"compose: empty agent_prompt.md is omitted",
	p_empty_agent,
	"PREAMBLE\n\nFLAVOR_PROMPT"
)

-- With no preamble configured → layers 2 + 3 only.
config.setup({ default_system_prompt = "BASE", nvim_agent_preamble = "" })
local sp2 = io.open(tmp_active .. "/system_prompt.md", "w")
sp2:write("FLAVOR")
sp2:close()
local ap2 = io.open(tmp_active .. "/agent_prompt.md", "w")
ap2:write("AGENT")
ap2:close()
local p_no_preamble = context.compose_system_prompt(tmp_active)
assert_eq("compose: empty preamble drops layer 1", p_no_preamble, "FLAVOR\n\nAGENT")

-- Preamble alone (no other layers) → just the preamble, no trailing blanks.
config.setup({ default_system_prompt = "", nvim_agent_preamble = "PREAMBLE_ONLY" })
local empty_dir = vim.fn.tempname()
vim.fn.mkdir(empty_dir, "p")
local p_only_preamble = context.compose_system_prompt(empty_dir)
assert_eq("compose: preamble-only (everything else empty)", p_only_preamble, "PREAMBLE_ONLY")
vim.fn.delete(empty_dir, "rf")

vim.fn.delete(tmp_active, "rf")

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
