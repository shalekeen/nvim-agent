-- Agent module integration test for nvim-agent.
-- Run with: nvim -l tests/agent_test.lua
--
-- Covers agent definitions, content load/save with template overlay, and
-- agent-template linking. Workspace manifest CRUD lives in workspace_test.lua.

-- ---------------------------------------------------------------------------
-- Bootstrapping (mirrors workspace_test.lua).
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

vim.opt.runtimepath:append(plugin_root)

-- Stub deps that the plugin's setup check requires.
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

-- Need a workspace initialized before agent definitions have a home.
workspace.init(cwd, ".test-defs")

-- ---------------------------------------------------------------------------
-- 1. Agent definitions: create, list, get, content round-trip, delete.
-- ---------------------------------------------------------------------------

assert_eq("agent.create('Alice') returns true", agent.create("Alice", cwd), true)
assert_eq("agent.create('Bob') returns true", agent.create("Bob", cwd), true)

local agents = agent.list(cwd)
check("agent.list returns 2 agents", #agents == 2, "got " .. #agents)
assert_eq("agent.list[1].name = Alice", agents[1].name, "Alice")
assert_eq("agent.list[2].name = Bob", agents[2].name, "Bob")

local alice = agent.get("Alice", cwd)
check("agent.get('Alice') returns table with name", alice ~= nil and alice.name == "Alice")
check("agent.get('Nonexistent') returns nil", agent.get("Nonexistent", cwd) == nil)

-- Write content into Alice's def dir, then load it into a fake session active dir.
local alice_def = agent.content_dir("Alice", cwd)
write(alice_def .. "/system_prompt.md", "Alice's prompt\n")
write(alice_def .. "/user_notes.md", "Be polite.\n")
write(alice_def .. "/persistent_dirs.json", '[{"tag":"src","path":"/tmp/src"}]')
write(alice_def .. "/role.md", "lead implementer\n")

local active_alice = sandbox .. "/sessions/main/active-alice"
vim.fn.mkdir(active_alice, "p")
local found = agent.load_content("Alice", active_alice, cwd)
assert_eq("agent.load_content returns true", found, true)
assert_eq("system_prompt.md copied to active_dir", read(active_alice .. "/system_prompt.md"), "Alice's prompt\n")
assert_eq("user_notes.md copied to active_dir", read(active_alice .. "/user_notes.md"), "Be polite.\n")
assert_eq("role.md copied to active_dir", read(active_alice .. "/role.md"), "lead implementer\n")

-- agent.save_content writes the active_dir back into the def dir (used by
-- the "save current session as flavor" workflow).
write(active_alice .. "/system_prompt.md", "Alice's prompt v2\n")
agent.save_content("Alice", active_alice, cwd)
assert_eq(
	"agent.save_content persists changes to def dir",
	read(alice_def .. "/system_prompt.md"),
	"Alice's prompt v2\n"
)

-- agent.delete removes the def dir.
agent.delete("Bob", cwd)
local agents_after_delete = agent.list(cwd)
check("agent.list returns 1 after deleting Bob", #agents_after_delete == 1)
assert_eq("remaining agent is Alice", agents_after_delete[1].name, "Alice")

-- ---------------------------------------------------------------------------
-- 2. Agent templates: create + load + link via .agent_meta.json + overlay.
-- ---------------------------------------------------------------------------

-- Create a template by writing the four template files into a source dir,
-- then calling template_create.
local template_src = sandbox .. "/template-src"
vim.fn.mkdir(template_src, "p")
write(template_src .. "/system_prompt.md", "TEMPLATE prompt\n")
write(template_src .. "/user_notes.md", "TEMPLATE notes\n")
write(template_src .. "/persistent_dirs.json", "[]")
write(template_src .. "/role.md", "TEMPLATE role\n")

assert_eq("template_create returns true", agent.template_create("SeniorSWE", template_src), true)
check(
	"template lives at base_dir/agent_templates/<name>/",
	vim.fn.filereadable(base_dir .. "/agent_templates/SeniorSWE/system_prompt.md") == 1
)

local templates = agent.template_list()
check("template_list returns SeniorSWE", #templates == 1 and templates[1] == "SeniorSWE")

-- template_load copies the template's files into a target dir (used at session
-- launch as the first step before agent overlays are applied).
local template_target = sandbox .. "/template-target"
vim.fn.mkdir(template_target, "p")
agent.template_load("SeniorSWE", template_target)
assert_eq("template_load copied system_prompt.md", read(template_target .. "/system_prompt.md"), "TEMPLATE prompt\n")
assert_eq("template_load copied role.md", read(template_target .. "/role.md"), "TEMPLATE role\n")

-- Linking: agent.set_template writes .agent_meta.json in the agent's def dir.
agent.set_template("Alice", "SeniorSWE", cwd)
assert_eq("agent.get_template returns SeniorSWE", agent.get_template("Alice", cwd), "SeniorSWE")
local meta_path = alice_def .. "/.agent_meta.json"
check("agent.set_template wrote .agent_meta.json", vim.fn.filereadable(meta_path) == 1)

-- The whole point of the template system: when agent.load_content runs and the
-- agent has a template link, the template is laid down first then the agent's
-- own files overlay on top. This is what fixes the "duplicated copies" concern.
local active_alice2 = sandbox .. "/sessions/main/active-alice2"
vim.fn.mkdir(active_alice2, "p")
agent.load_content("Alice", active_alice2, cwd)

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
agent.load_content("Alice", active_alice3, cwd)
assert_eq("template overlay: template fills missing role.md", read(active_alice3 .. "/role.md"), "TEMPLATE role\n")

-- template_delete removes from disk.
agent.template_delete("SeniorSWE", cwd)
check("template_delete removed dir", vim.fn.isdirectory(base_dir .. "/agent_templates/SeniorSWE") == 0)

-- ---------------------------------------------------------------------------
-- 3. Cross-module: agent.delete must scrub the agent from any workspace
-- manifests that referenced it. This is the workspace.remove_agent_from_workspaces
-- hook called by agent.delete.
-- ---------------------------------------------------------------------------

agent.create("Charlie", cwd)
workspace.workspace_save({
	name = "deletion-test",
	agents = {
		{ name = "Alice", role = "lead" },
		{ name = "Charlie", role = "helper" },
	},
}, cwd)

agent.delete("Charlie", cwd)
local ws = workspace.workspace_get("deletion-test", cwd)
check("workspace exists after deleting one of its agents", ws ~= nil)
check("workspace lost the deleted agent", ws and #ws.agents == 1)
assert_eq("remaining agent in workspace is Alice", ws and ws.agents[1].name, "Alice")

-- ---------------------------------------------------------------------------
-- 4. Unit tests — edge cases, error paths, and idempotence.
-- Each block is independent and runs against the same Alice fixture above.
-- ---------------------------------------------------------------------------

-- 4a. AGENT_FILES is exported and contains the known canonical entries.
check("AGENT_FILES is exported as a table", type(agent.AGENT_FILES) == "table")
local has = {}
for _, f in ipairs(agent.AGENT_FILES) do
	has[f] = true
end
check("AGENT_FILES contains system_prompt.md", has["system_prompt.md"] == true)
check("AGENT_FILES contains role.md", has["role.md"] == true)
check("AGENT_FILES contains user_notes.md", has["user_notes.md"] == true)
check("AGENT_FILES contains persistent_dirs.json", has["persistent_dirs.json"] == true)
check("AGENT_FILES contains .flavor_meta.json", has[".flavor_meta.json"] == true)
check("AGENT_FILES contains permissions.json", has["permissions.json"] == true)
check("AGENT_FILES contains agent_prompt.md", has["agent_prompt.md"] == true)

-- 4b. agent.create is idempotent — calling on an existing agent succeeds and
-- does NOT clobber an already-non-empty system_prompt.md.
write(alice_def .. "/system_prompt.md", "Alice's prompt v2\n") -- ensure non-empty
assert_eq("agent.create on existing agent returns true", agent.create("Alice", cwd), true)
assert_eq(
	"agent.create idempotent: system_prompt.md not clobbered",
	read(alice_def .. "/system_prompt.md"),
	"Alice's prompt v2\n"
)

-- 4c. agent.delete on a nonexistent name returns false (not nil, not error).
assert_eq("agent.delete('Nonexistent') returns false", agent.delete("Nonexistent", cwd), false)

-- 4d. agent.load_content on a nonexistent agent returns false.
local empty_dir = sandbox .. "/empty-target"
vim.fn.mkdir(empty_dir, "p")
assert_eq("agent.load_content('Nonexistent') returns false", agent.load_content("Nonexistent", empty_dir, cwd), false)

-- 4e. agent.template_load on a missing template returns false and writes nothing.
local empty_target = sandbox .. "/template-load-empty"
vim.fn.mkdir(empty_target, "p")
assert_eq(
	"agent.template_load('NoSuchTemplate') returns false",
	agent.template_load("NoSuchTemplate", empty_target),
	false
)
check(
	"missing template_load leaves target dir untouched",
	vim.fn.filereadable(empty_target .. "/system_prompt.md") == 0
)

-- 4f. agent.template_delete on a missing template returns false.
assert_eq("agent.template_delete('NoSuchTemplate') returns false", agent.template_delete("NoSuchTemplate", cwd), false)

-- 4g. set_template(name, nil, cwd) clears the link → get_template returns nil.
agent.set_template("Alice", "ScratchTemplate", cwd)
assert_eq("set_template links agent", agent.get_template("Alice", cwd), "ScratchTemplate")
agent.set_template("Alice", nil, cwd)
check(
	"set_template(name, nil) clears template link",
	agent.get_template("Alice", cwd) == nil or agent.get_template("Alice", cwd) == vim.NIL
)

-- 4h. get_template for an agent that never had .agent_meta.json returns nil.
agent.create("FreshAgent", cwd)
check("get_template returns nil for agent with no meta", agent.get_template("FreshAgent", cwd) == nil)

-- 4i. content_dir is a pure path constructor: returns a path even before the
-- agent directory exists (caller is expected to mkdir as needed).
local path_before_create = agent.content_dir("WillCreate", cwd)
check(
	"content_dir returns a path before agent exists",
	type(path_before_create) == "string" and path_before_create:match("/WillCreate$") ~= nil
)
check("content_dir path is NOT yet a directory", vim.fn.isdirectory(path_before_create) == 0)

-- ---------------------------------------------------------------------------
-- 5. Unit tests — behavior when no workspace is initialized in cwd.
-- Uses a fresh, never-initialized cwd. content_dir/list/create/delete all
-- need to fail gracefully (no exceptions, defined return values).
-- ---------------------------------------------------------------------------

local unconfigured_cwd = sandbox .. "/no-workspace-here"
vim.fn.mkdir(unconfigured_cwd, "p")

check("content_dir returns nil with no workspace", agent.content_dir("X", unconfigured_cwd) == nil)
check("list returns empty table with no workspace", #agent.list(unconfigured_cwd) == 0)
assert_eq("create returns false with no workspace", agent.create("X", unconfigured_cwd), false)
-- delete on a missing-workspace cwd: dir lookup returns nil → returns false,
-- and does not call workspace.remove_agent_from_workspaces.
assert_eq("delete returns false with no workspace", agent.delete("X", unconfigured_cwd), false)
check(
	"ensure_flavor_meta is a no-op when there's no workspace",
	(function()
		local ok = pcall(agent.ensure_flavor_meta, "X", unconfigured_cwd)
		return ok
	end)()
)

-- ---------------------------------------------------------------------------
-- 6. ensure_flavor_meta — the regression test for "workspace re-prompts
-- the picker every launch" bug. workspace_launch checks
-- <def_dir>/<agent>/.flavor_meta.json to decide whether to skip the picker.
-- This helper plants that marker for non-global-flavor launch paths.
-- ---------------------------------------------------------------------------

agent.create("Lead", cwd)
local lead_meta = agent.content_dir("Lead", cwd) .. "/.flavor_meta.json"
check("setup: Lead has no .flavor_meta.json yet", vim.fn.filereadable(lead_meta) == 0)

agent.ensure_flavor_meta("Lead", cwd)
check("ensure_flavor_meta creates the marker", vim.fn.filereadable(lead_meta) == 1)

-- Content shape: { flavor = "<agent>", checkpoint = nil }
local meta_raw = io.open(lead_meta, "r"):read("*a")
check(
	"ensure_flavor_meta writes flavor = agent_name",
	meta_raw:find('"flavor":"Lead"', 1, true) ~= nil,
	"got " .. meta_raw
)

-- Idempotence: a SECOND call must NOT clobber pre-existing meta. This
-- guards against the helper accidentally overwriting a global flavor link
-- that was set by sel.type == "global".
local handle = io.open(lead_meta, "w")
handle:write('{"flavor":"some-global-flavor","checkpoint":"v2"}')
handle:close()
agent.ensure_flavor_meta("Lead", cwd)
local preserved = io.open(lead_meta, "r"):read("*a")
assert_eq(
	"ensure_flavor_meta does NOT overwrite existing meta",
	preserved,
	'{"flavor":"some-global-flavor","checkpoint":"v2"}'
)

-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
