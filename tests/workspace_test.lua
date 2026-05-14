-- Workspace integration test for nvim-agent.
-- Run with: nvim -l tests/workspace_test.lua
--
-- Covers the workspace-module surface: init, runtime dir layout, manifest
-- CRUD (workspace_list/get/save/delete), and atomic config persistence.
-- Agent-definition tests live in tests/agent_test.lua.

-- ---------------------------------------------------------------------------
-- Bootstrapping (mirrors tests/integration_test.lua).
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

vim.opt.runtimepath:append(plugin_root)

-- Stub deps that workspace.lua doesn't actually need but the plugin's setup
-- check requires when we wire up config (we never call M.setup here, but be
-- safe for any indirect requires).
package.preload["which-key"] = function()
	return { add = function() end, register = function() end }
end
package.preload["barbar"] = function()
	return {}
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

local function read(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function write(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	f:write(content)
	f:close()
end

-- ---------------------------------------------------------------------------
-- Test sandbox: temp project cwd + temp ~/.nvim-agent equivalent.
-- ---------------------------------------------------------------------------

local sandbox = vim.fn.tempname()
local cwd = sandbox .. "/project"
local base_dir = sandbox .. "/dot-nvim-agent"
vim.fn.mkdir(cwd, "p")
vim.fn.mkdir(base_dir, "p")

local config = require("nvim-agent.config")
config.setup({ base_dir = base_dir })

local workspace = require("nvim-agent.workspace")
local agent = require("nvim-agent.agent")

-- ---------------------------------------------------------------------------
-- 1. workspace.init creates def_dir + .nvim-agent runtime + config.json
--    pointing at the chosen def_dir.
-- ---------------------------------------------------------------------------

local def_dir = workspace.init(cwd, ".test-defs")
check("workspace.init returns def_dir path", def_dir == cwd .. "/.test-defs", "got " .. tostring(def_dir))
check("def_dir exists after init", vim.fn.isdirectory(cwd .. "/.test-defs") == 1)
check("runtime .nvim-agent/messages exists", vim.fn.isdirectory(cwd .. "/.nvim-agent/messages") == 1)
check("runtime .nvim-agent/status exists", vim.fn.isdirectory(cwd .. "/.nvim-agent/status") == 1)
check("runtime .nvim-agent/history exists", vim.fn.isdirectory(cwd .. "/.nvim-agent/history") == 1)
check("workspace_def_dir written to config.json", workspace.read_config(cwd).workspace_def_dir == ".test-defs")
check("has_workspace returns true after init", workspace.has_workspace(cwd) == true)

-- ---------------------------------------------------------------------------
-- 2. Workspace manifests: save → list → launchable structure → delete.
--    Agent fixtures are created via agent.create so the manifest entries
--    point at real def dirs (matches production behavior).
-- ---------------------------------------------------------------------------

agent.create("Alice", cwd)
agent.create("Bob", cwd)

workspace.workspace_save({
	name = "feature-dev",
	agents = {
		{ name = "Alice", role = "lead" },
		{ name = "Bob", role = "reviewer" },
	},
}, cwd)

local manifests = workspace.workspace_list(cwd)
check("workspace_list returns 1 manifest", #manifests == 1, "got " .. #manifests)
assert_eq("manifest name", manifests[1].name, "feature-dev")
check("manifest has 2 agents", manifests[1].agents and #manifests[1].agents == 2)
assert_eq("manifest agent[1].name", manifests[1].agents[1].name, "Alice")
assert_eq("manifest agent[1].role", manifests[1].agents[1].role, "lead")
assert_eq("manifest agent[2].name", manifests[1].agents[2].name, "Bob")

-- File should be JSON on disk.
local manifest_path = cwd .. "/.test-defs/workspaces/feature-dev.json"
local raw = read(manifest_path)
check("manifest JSON file written", raw ~= nil and raw:find('"name":"feature%-dev"') ~= nil)

workspace.workspace_delete("feature-dev", cwd)
check("workspace_delete removed manifest", #workspace.workspace_list(cwd) == 0)

-- ---------------------------------------------------------------------------
-- 3. atomic write_json: a half-written file from an earlier crash must not
--    corrupt the read path. Simulate by writing garbage to config.json then
--    confirm read_config returns nil (treats it as missing) rather than
--    throwing.
-- ---------------------------------------------------------------------------

write(workspace.config_path(cwd), "{not valid json")
check("read_config returns nil on corrupt file", workspace.read_config(cwd) == nil)

-- A subsequent write_config (via workspace.init or any caller) replaces it
-- atomically. Verify the .tmp file doesn't linger.
workspace.write_config(cwd, { workspace_def_dir = ".test-defs" })
check("config.json valid after rewrite", workspace.read_config(cwd).workspace_def_dir == ".test-defs")
check("no .tmp file lingers", vim.fn.filereadable(workspace.config_path(cwd) .. ".tmp") == 0)

-- ---------------------------------------------------------------------------
-- 4. Unit tests — error paths and pure-constructor helpers.
-- ---------------------------------------------------------------------------

-- 4a. runtime_dir is a pure path constructor: returns a path regardless of
-- whether the directory exists. Callers are expected to mkdir as needed.
local fresh = sandbox .. "/uninitialized-project"
vim.fn.mkdir(fresh, "p")
assert_eq("runtime_dir always returns <cwd>/.nvim-agent", workspace.runtime_dir(fresh), fresh .. "/.nvim-agent")
check("runtime_dir does NOT create the directory", vim.fn.isdirectory(fresh .. "/.nvim-agent") == 0)

-- 4b. Without init, has_workspace is false and def_dir is nil.
check("has_workspace false on uninitialized cwd", workspace.has_workspace(fresh) == false)
check("def_dir nil on uninitialized cwd", workspace.def_dir(fresh) == nil)

-- 4c. read_config returns nil when no config.json exists.
check("read_config returns nil when config.json missing", workspace.read_config(fresh) == nil)

-- 4d. workspace_list/workspace_get return empty/nil before init.
assert_eq("workspace_list returns empty on uninitialized cwd", #workspace.workspace_list(fresh), 0)
check("workspace_get returns nil on uninitialized cwd", workspace.workspace_get("anything", fresh) == nil)

-- 4e. workspace_get on the configured cwd but missing-manifest returns nil.
check("workspace_get('NoSuchManifest') returns nil after init", workspace.workspace_get("NoSuchManifest", cwd) == nil)

-- 4f. workspace_delete on a missing manifest returns false.
assert_eq(
	"workspace_delete on missing manifest returns false",
	workspace.workspace_delete("NoSuchManifest", cwd),
	false
)

-- ---------------------------------------------------------------------------
-- 5. Unit tests — remove_agent_from_workspaces edge cases.
-- This is the workspace-side reaction to agent.delete; it must be a no-op
-- when the agent appears in zero manifests, and it must touch ALL manifests
-- that reference the agent (not just the first one).
-- ---------------------------------------------------------------------------

-- 5a. No-op when the agent isn't in any manifest.
workspace.workspace_save({
	name = "ws-without-ghost",
	agents = { { name = "Alice", role = "lead" } },
}, cwd)
workspace.remove_agent_from_workspaces("GhostAgent", cwd)
local untouched = workspace.workspace_get("ws-without-ghost", cwd)
check("no-op: manifest still exists", untouched ~= nil)
check("no-op: untouched manifest still has Alice", untouched and #untouched.agents == 1)

-- 5b. Strips the agent from MULTIPLE manifests in one call.
agent.create("Removable", cwd)
workspace.workspace_save({
	name = "ws-a",
	agents = { { name = "Alice" }, { name = "Removable" } },
}, cwd)
workspace.workspace_save({
	name = "ws-b",
	agents = { { name = "Removable" }, { name = "Bob" } },
}, cwd)
workspace.remove_agent_from_workspaces("Removable", cwd)

local ws_a = workspace.workspace_get("ws-a", cwd)
local ws_b = workspace.workspace_get("ws-b", cwd)
check("ws-a no longer contains Removable", ws_a and #ws_a.agents == 1 and ws_a.agents[1].name == "Alice")
check("ws-b no longer contains Removable", ws_b and #ws_b.agents == 1 and ws_b.agents[1].name == "Bob")

-- ---------------------------------------------------------------------------
-- 6. Unit tests — save_current_as guards.
-- save_current_as is the live-session snapshotter. It MUST refuse to run
-- when no workspace is initialized AND when no live sessions exist (it's
-- read-only against session_mod.list()).
-- ---------------------------------------------------------------------------

-- 6a. Refuses on an uninitialized cwd.
assert_eq("save_current_as returns false on uninitialized cwd", workspace.save_current_as("anything", fresh), false)

-- 6b. Refuses when workspace is initialized but no live sessions exist.
-- session_mod.list() in this headless test context returns empty.
assert_eq(
	"save_current_as returns false when no live sessions",
	workspace.save_current_as("would-be-snapshot", cwd),
	false
)
check("save_current_as didn't create a manifest when refused", workspace.workspace_get("would-be-snapshot", cwd) == nil)

-- ---------------------------------------------------------------------------
-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
