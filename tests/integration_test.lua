-- Integration test for nvim-agent's pure-Lua surface.
-- Run with: nvim -l tests/integration_test.lua
--
-- Exits with status 1 if any check fails. Runnable from a fresh checkout
-- without the user's full nvim config; which-key and barbar are stubbed.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(plugin_root)

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

local fail_count, total = 0, 0
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

-- Everything that touches the filesystem runs against a sandbox base_dir so
-- the suite never writes into the user's real ~/.nvim-agent.
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")

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
	type(cfg.nvim_agent_preamble) == "string" and cfg.nvim_agent_preamble:find("nvim%-agent") ~= nil
)

-- ---------------------------------------------------------------------------
-- 2. context.compose_system_prompt — layered composition:
--      1.  config.nvim_agent_preamble      (always first)
--      1b. adapter:get_context_contract()  (omitted when no adapter / "")
--      2.  <active_dir>/role.md            ("# Your role" section; omitted when missing)
--      3.  <active_dir>/system_prompt.md   (or config.default_system_prompt)
--    Each non-empty layer is joined by a single blank line. This first block
--    runs with NO active adapter, so layer 1b is absent.
-- ---------------------------------------------------------------------------

local context = require("nvim-agent.context")
config.setup({ default_system_prompt = "BASE_PROMPT", nvim_agent_preamble = "PREAMBLE" })

assert_eq("compose: preamble + default (no active_dir)", context.compose_system_prompt(nil), "PREAMBLE\n\nBASE_PROMPT")

local tmp_active = sandbox .. "/active"
vim.fn.mkdir(tmp_active, "p")
assert_eq("compose: empty active dir falls back to default", context.compose_system_prompt(tmp_active), "PREAMBLE\n\nBASE_PROMPT")

local function put(name, content)
	local f = io.open(tmp_active .. "/" .. name, "w")
	f:write(content)
	f:close()
end

put("system_prompt.md", "AGENT_PROMPT")
assert_eq("compose: system_prompt.md overrides default", context.compose_system_prompt(tmp_active), "PREAMBLE\n\nAGENT_PROMPT")

put("role.md", "lead implementer\n")
assert_eq(
	"compose: role becomes a '# Your role' section before the prompt",
	context.compose_system_prompt(tmp_active),
	"PREAMBLE\n\n# Your role\n\nlead implementer\n\nAGENT_PROMPT"
)

put("role.md", "   \n")
assert_eq("compose: blank role.md is omitted", context.compose_system_prompt(tmp_active), "PREAMBLE\n\nAGENT_PROMPT")

-- agent_prompt.md is no longer a layer: an agent IS the prompt.
put("agent_prompt.md", "SHOULD_NOT_APPEAR")
check("compose: agent_prompt.md is ignored", context.compose_system_prompt(tmp_active):find("SHOULD_NOT_APPEAR") == nil)

config.setup({ default_system_prompt = "BASE", nvim_agent_preamble = "" })
put("system_prompt.md", "AGENT")
put("role.md", "R")
assert_eq("compose: empty preamble drops layer 1", context.compose_system_prompt(tmp_active), "# Your role\n\nR\n\nAGENT")

config.setup({ default_system_prompt = "", nvim_agent_preamble = "PREAMBLE_ONLY" })
local empty_dir = sandbox .. "/empty-active"
vim.fn.mkdir(empty_dir, "p")
assert_eq("compose: preamble-only (everything else empty)", context.compose_system_prompt(empty_dir), "PREAMBLE_ONLY")

-- ---------------------------------------------------------------------------
-- 2b. Layer 1b: the active adapter's context contract sits between the
--     preamble and the role/prompt. CLI-specific text (hook names, native
--     tool names, permission grammar) must live here, never in core.
-- ---------------------------------------------------------------------------

local adapter_mod = require("nvim-agent.adapter")
config.setup({ default_system_prompt = "BASE_PROMPT", nvim_agent_preamble = "PREAMBLE" })

adapter_mod.set_active(adapter_mod.new({
	get_context_contract = function()
		return "CONTRACT"
	end,
}))
assert_eq("compose: adapter contract is layer 1b", context.compose_system_prompt(nil), "PREAMBLE\n\nCONTRACT\n\nBASE_PROMPT")
put("system_prompt.md", "AGENT_PROMPT")
put("role.md", "R")
assert_eq(
	"compose: full order preamble / contract / role / prompt",
	context.compose_system_prompt(tmp_active),
	"PREAMBLE\n\nCONTRACT\n\n# Your role\n\nR\n\nAGENT_PROMPT"
)

adapter_mod.set_active(adapter_mod.new({
	get_context_contract = function()
		return ""
	end,
}))
assert_eq("compose: empty adapter contract is dropped", context.compose_system_prompt(nil), "PREAMBLE\n\nBASE_PROMPT")

-- Base adapter defaults are CLI-neutral: read-on-demand contract, no grants.
local base = adapter_mod.new({})
local base_contract = base:get_context_contract()
check("base contract is a non-empty string", type(base_contract) == "string" and #base_contract > 0)
check("base contract carries no Claude Code vocabulary", not base_contract:find("UserPromptSubmit") and not base_contract:find("Claude"))
local base_perms = base:get_agent_permissions({ active_dir = tmp_active })
check("base permissions grant nothing", type(base_perms) == "table" and #base_perms.allow == 0 and #base_perms.deny == 0)

-- The bundled Claude Code adapter: hook contract, profiles from the session mirror.
local cc = require("nvim-agent.adapter.claude_code")
check("claude_code contract names the UserPromptSubmit hook", cc:get_context_contract():find("UserPromptSubmit") ~= nil)
check("claude_code contract warns off built-in file tools", cc:get_context_contract():find("built%-in Read") ~= nil)
check(
	"claude_code default permissions are its 'full' profile",
	vim.tbl_contains(cc:get_agent_permissions({ active_dir = tmp_active }).allow, "mcp__nvim-agent__*")
)
put("permissions.json", '{"profile":"oversight"}')
local oversight = cc:get_agent_permissions({ active_dir = tmp_active })
check(
	"claude_code reads permissions.json from the session active_dir",
	vim.tbl_contains(oversight.allow, "mcp__nvim-agent__read_file") and not vim.tbl_contains(oversight.allow, "Write(*)")
)
put("permissions.json", '{"allow":["Read(*)"],"deny":["Bash(*)"]}')
local custom = cc:get_agent_permissions({ active_dir = tmp_active })
check("claude_code honours a custom allow/deny spec", #custom.allow == 1 and custom.allow[1] == "Read(*)" and custom.deny[1] == "Bash(*)")
check("claude_code permissions with no session fall back to full", vim.tbl_contains(cc:get_agent_permissions(nil).allow, "Bash(*)"))

-- The shipped core preamble must stay free of any harness's vocabulary, and
-- of the retired flavor concept.
local shipped_preamble = config.defaults.nvim_agent_preamble
check(
	"core preamble has no hook / Claude Code / built-in tool references",
	not shipped_preamble:find("UserPromptSubmit")
		and not shipped_preamble:find("Claude")
		and not shipped_preamble:find("built%-in Read")
		and not shipped_preamble:find("CRITICAL")
)
check("core preamble no longer mentions flavors or checkpoints", not shipped_preamble:find("flavor") and not shipped_preamble:find("checkpoint"))
check("core preamble describes role.md as the delegation surface", shipped_preamble:find("role%.md") ~= nil and shipped_preamble:find("delegate") ~= nil)

adapter_mod.set_active(nil)

-- ---------------------------------------------------------------------------
-- 3. mcp/server.lua resolves on the runtimepath (claude_code relies on this
--    to spawn the MCP server regardless of plugin manager).
-- ---------------------------------------------------------------------------

local resolved = vim.api.nvim_get_runtime_file("lua/nvim-agent/mcp/server.lua", false)
check("runtime_file resolves mcp/server.lua", #resolved >= 1 and resolved[1]:match("/mcp/server%.lua$") ~= nil)

-- ---------------------------------------------------------------------------
-- 4. M.setup: hard-dep checks, agents/ dir creation, no stray startup.
--    Uses the sandbox base_dir so the real ~/.nvim-agent is untouched.
-- ---------------------------------------------------------------------------

local setup_base = sandbox .. "/setup-base"
package.loaded["nvim-agent"] = nil
local ok_setup, err_setup = pcall(function()
	require("nvim-agent").setup({ adapter = "claude_code", base_dir = setup_base, auto_open = false })
end)
check("setup() succeeds when which-key + barbar are present", ok_setup, err_setup)
check("setup() creates <base_dir>/agents/", vim.fn.isdirectory(setup_base .. "/agents") == 1)

-- The hook script lands under the sandbox base_dir, not the user's home.
check("adapter setup wrote the hook under the sandbox base_dir", vim.fn.filereadable(setup_base .. "/hooks/claude_code_prompt.sh") == 1)

-- Statusline is empty with no session.
assert_eq("statusline empty without a session", require("nvim-agent").statusline(), "")

package.preload["barbar"] = nil
package.loaded["barbar"] = nil
package.loaded["nvim-agent"] = nil
local ok_no_barbar, err_no_barbar = pcall(function()
	require("nvim-agent").setup({ adapter = "claude_code", base_dir = setup_base })
end)
check(
	"setup() errors when barbar is missing",
	(not ok_no_barbar) and tostring(err_no_barbar):find("barbar%.nvim is required") ~= nil,
	"expected barbar-required error, got: " .. tostring(err_no_barbar)
)

-- ---------------------------------------------------------------------------
-- Cleanup + summary
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
