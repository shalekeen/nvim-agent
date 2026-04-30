-- Workspace integration test for nvim-agent.
-- Run with: nvim -l tests/workspace_test.lua
--
-- Covers the project-mode surface: workspace init, agent definitions,
-- content load with template overlay, agent-template linking, and the
-- workspace manifest CRUD. No real claude CLI or nvim socket required.

-- ---------------------------------------------------------------------------
-- Bootstrapping (mirrors tests/integration_test.lua).
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

package.path = plugin_root .. "/lua/?.lua;"
	.. plugin_root .. "/lua/?/init.lua;"
	.. package.path

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
-- 2. Agent definitions: create, list, get, content round-trip, delete.
-- ---------------------------------------------------------------------------

assert_eq("agent_create('Alice') returns true", workspace.agent_create("Alice", cwd), true)
assert_eq("agent_create('Bob') returns true", workspace.agent_create("Bob", cwd), true)

local agents = workspace.agent_list(cwd)
check("agent_list returns 2 agents", #agents == 2, "got " .. #agents)
assert_eq("agent_list[1].name = Alice", agents[1].name, "Alice")
assert_eq("agent_list[2].name = Bob", agents[2].name, "Bob")

local alice = workspace.agent_get("Alice", cwd)
check("agent_get('Alice') returns table with name", alice ~= nil and alice.name == "Alice")
check("agent_get('Nonexistent') returns nil", workspace.agent_get("Nonexistent", cwd) == nil)

-- Write content into Alice's def dir, then load it into a fake session active dir.
local alice_def = workspace.agent_content_dir("Alice", cwd)
write(alice_def .. "/system_prompt.md", "Alice's prompt\n")
write(alice_def .. "/user_notes.md", "Be polite.\n")
write(alice_def .. "/persistent_dirs.json", '[{"tag":"src","path":"/tmp/src"}]')
write(alice_def .. "/role.md", "lead implementer\n")

local active_alice = sandbox .. "/sessions/main/active-alice"
vim.fn.mkdir(active_alice, "p")
local found = workspace.agent_load_content("Alice", active_alice, cwd)
assert_eq("agent_load_content returns true", found, true)
assert_eq("system_prompt.md copied to active_dir", read(active_alice .. "/system_prompt.md"), "Alice's prompt\n")
assert_eq("user_notes.md copied to active_dir", read(active_alice .. "/user_notes.md"), "Be polite.\n")
assert_eq("role.md copied to active_dir", read(active_alice .. "/role.md"), "lead implementer\n")

-- agent_save_content writes the active_dir back into the def dir (used by
-- the "save current session as flavor" workflow).
write(active_alice .. "/system_prompt.md", "Alice's prompt v2\n")
workspace.agent_save_content("Alice", active_alice, cwd)
assert_eq(
	"agent_save_content persists changes to def dir",
	read(alice_def .. "/system_prompt.md"),
	"Alice's prompt v2\n"
)

-- agent_delete removes the def dir.
workspace.agent_delete("Bob", cwd)
local agents_after_delete = workspace.agent_list(cwd)
check("agent_list returns 1 after deleting Bob", #agents_after_delete == 1)
assert_eq("remaining agent is Alice", agents_after_delete[1].name, "Alice")

-- ---------------------------------------------------------------------------
-- 3. Agent templates: create + load + link via .agent_meta.json + overlay.
-- ---------------------------------------------------------------------------

-- Create a template by writing the four template files into a source dir,
-- then calling template_create.
local template_src = sandbox .. "/template-src"
vim.fn.mkdir(template_src, "p")
write(template_src .. "/system_prompt.md", "TEMPLATE prompt\n")
write(template_src .. "/user_notes.md", "TEMPLATE notes\n")
write(template_src .. "/persistent_dirs.json", "[]")
write(template_src .. "/role.md", "TEMPLATE role\n")

assert_eq("template_create returns true", workspace.template_create("SeniorSWE", template_src), true)
check(
	"template lives at base_dir/agent_templates/<name>/",
	vim.fn.filereadable(base_dir .. "/agent_templates/SeniorSWE/system_prompt.md") == 1
)

local templates = workspace.template_list()
check("template_list returns SeniorSWE", #templates == 1 and templates[1] == "SeniorSWE")

-- template_load copies the template's files into a target dir (used at session
-- launch as the first step before agent overlays are applied).
local template_target = sandbox .. "/template-target"
vim.fn.mkdir(template_target, "p")
workspace.template_load("SeniorSWE", template_target)
assert_eq(
	"template_load copied system_prompt.md",
	read(template_target .. "/system_prompt.md"),
	"TEMPLATE prompt\n"
)
assert_eq("template_load copied role.md", read(template_target .. "/role.md"), "TEMPLATE role\n")

-- Linking: agent_set_template writes .agent_meta.json in the agent's def dir.
workspace.agent_set_template("Alice", "SeniorSWE", cwd)
assert_eq("agent_get_template returns SeniorSWE", workspace.agent_get_template("Alice", cwd), "SeniorSWE")
local meta_path = alice_def .. "/.agent_meta.json"
check("agent_set_template wrote .agent_meta.json", vim.fn.filereadable(meta_path) == 1)

-- The whole point of the template system: when agent_load_content runs and the
-- agent has a template link, the template is laid down first then the agent's
-- own files overlay on top. This is what fixes the "duplicated copies" concern.
local active_alice2 = sandbox .. "/sessions/main/active-alice2"
vim.fn.mkdir(active_alice2, "p")
workspace.agent_load_content("Alice", active_alice2, cwd)

-- system_prompt.md was overridden by Alice's def dir → Alice wins.
assert_eq(
	"template overlay: agent's system_prompt.md wins",
	read(active_alice2 .. "/system_prompt.md"),
	"Alice's prompt v2\n"
)
-- role.md was set on the agent → Alice wins.
assert_eq("template overlay: agent's role.md wins", read(active_alice2 .. "/role.md"), "lead implementer\n")
-- The template wrote user_notes.md = "TEMPLATE notes\n" but Alice also has a
-- user_notes.md = "Be polite.\n", so Alice wins. This also confirms the
-- overlay actually runs (rather than the raw template leaking through).
assert_eq("template overlay: agent's user_notes.md wins", read(active_alice2 .. "/user_notes.md"), "Be polite.\n")

-- Now blow away one of Alice's files and confirm the template fills the gap.
os.remove(alice_def .. "/role.md")
local active_alice3 = sandbox .. "/sessions/main/active-alice3"
vim.fn.mkdir(active_alice3, "p")
workspace.agent_load_content("Alice", active_alice3, cwd)
assert_eq(
	"template overlay: template fills missing role.md",
	read(active_alice3 .. "/role.md"),
	"TEMPLATE role\n"
)

-- template_delete removes from disk.
workspace.template_delete("SeniorSWE", cwd)
check("template_delete removed dir", vim.fn.isdirectory(base_dir .. "/agent_templates/SeniorSWE") == 0)

-- ---------------------------------------------------------------------------
-- 4. Workspace manifests: save → list → launchable structure → delete.
-- ---------------------------------------------------------------------------

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
-- 5. atomic write_json: a half-written file from an earlier crash must not
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
-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
