-- Workspace + session model tests.
-- Run with: nvim -l tests/workspace_test.lua
--
-- Covers <cwd>/.nvim-agent/workspaces/<name>/workspace.json manifests
-- (ephemeral first, auto-save on every membership change), the per-instance
-- runtime tree, and the session registry's membership-vs-liveness split.

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
local function read(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local c = f:read("*a")
	f:close()
	return c
end
local function write(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	f:write(content)
	f:close()
end

-- ---------------------------------------------------------------------------
-- Sandbox
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
local session = require("nvim-agent.session")

agent.create("Alice", { role = "lead" })
agent.create("Bob", { role = "reviewer" })

-- ---------------------------------------------------------------------------
-- 1. Per-instance runtime tree
-- ---------------------------------------------------------------------------

check(
	"session.instance_id is a v4 UUID",
	type(session.instance_id) == "string"
		and #session.instance_id == 36
		and session.instance_id:match("^%x+%-%x+%-4%x%x%x%-[89ab]%x%x%x%-%x+$") ~= nil,
	"got " .. tostring(session.instance_id)
)
local inst_dir = workspace.instance_runtime_dir(cwd)
assert_eq("instance_runtime_dir = <cwd>/.nvim-agent/instances/<id>", inst_dir, cwd .. "/.nvim-agent/instances/" .. session.instance_id)
assert_eq("init_runtime returns the instance dir", workspace.init_runtime(cwd), inst_dir)
assert_eq("history_dir lives under the workspace dir", workspace.history_dir("team", cwd), cwd .. "/.nvim-agent/workspaces/team/history")
for _, sub in ipairs({ "messages", "status", "history", "triggers" }) do
	check("instance " .. sub .. "/ exists", vim.fn.isdirectory(inst_dir .. "/" .. sub) == 1)
end
check("no shared project-level status/ is created", vim.fn.isdirectory(cwd .. "/.nvim-agent/status") == 0)

-- ---------------------------------------------------------------------------
-- 2. Manifests: none yet → new → save → read → list (ephemeral first)
-- ---------------------------------------------------------------------------

check("any_exist false on a fresh project", workspace.any_exist(cwd) == false)
assert_eq("list is empty on a fresh project", #workspace.list(cwd), 0)
check("read of missing manifest is nil", workspace.read("nope", cwd) == nil)

local eph = workspace.new_manifest(workspace.EPHEMERAL)
assert_eq("save ephemeral", workspace.save(eph, cwd), true)
check("manifest lives at workspaces/ephemeral/workspace.json", vim.fn.filereadable(cwd .. "/.nvim-agent/workspaces/ephemeral/workspace.json") == 1)
check("any_exist true after first save", workspace.any_exist(cwd) == true)

local named = workspace.new_manifest("feature-dev")
workspace.save(named, cwd)
local aaa = workspace.new_manifest("aaa-first-alphabetically")
workspace.save(aaa, cwd)

local all = workspace.list(cwd)
assert_eq("list has 3 manifests", #all, 3)
assert_eq("ephemeral is listed first regardless of name", all[1].name, "ephemeral")
check("ephemeral flagged", all[1].ephemeral == true)
assert_eq("then sorted by name", all[2].name, "aaa-first-alphabetically")
assert_eq("then sorted by name (2)", all[3].name, "feature-dev")
check("named not flagged ephemeral", all[3].ephemeral == false)

-- Path traversal: names reaching the filesystem are validated everywhere.
for _, evil in ipairs({ "..", "../..", "../instances", ".hidden", "a/b" }) do
	check("read rejects " .. evil, workspace.read(evil, cwd) == nil)
	check("exists rejects " .. evil, workspace.exists(evil, cwd) == false)
	check("delete rejects " .. evil, workspace.delete(evil, cwd) == false)
	check("rename-from rejects " .. evil, workspace.rename(evil, "x", cwd) == false)
end
check("project dir survived traversal attempts", vim.fn.isdirectory(cwd) == 1 and vim.fn.isdirectory(cwd .. "/.nvim-agent/instances") == 1)

-- Name validation: 'ephemeral' reserved for user workspaces.
check("validate_name rejects 'ephemeral' for user workspaces", workspace.validate_name("ephemeral") == false)
check("validate_name allows 'ephemeral' when asked", workspace.validate_name("ephemeral", true) == true)
check("validate_name rejects slash", workspace.validate_name("a/b") == false)
check("validate_name rejects empty", workspace.validate_name("") == false)

-- ---------------------------------------------------------------------------
-- 3. Membership: every add/remove is persisted immediately
-- ---------------------------------------------------------------------------

local ok_unknown, err_unknown = workspace.add_entry(named, { agent = "Nobody" }, cwd)
check("add_entry rejects unknown library agent", not ok_unknown and err_unknown:find("not found") ~= nil, tostring(err_unknown))

assert_eq("add Alice (name defaults to agent)", workspace.add_entry(named, { agent = "Alice" }, cwd), true)
local on_disk = workspace.read("feature-dev", cwd)
check("add persisted immediately", on_disk and #on_disk.agents == 1 and on_disk.agents[1].name == "Alice" and on_disk.agents[1].agent == "Alice")

local ok_dupname, err_dupname = workspace.add_entry(named, { agent = "Bob", name = "Alice" }, cwd)
check("duplicate session name rejected", not ok_dupname and err_dupname:find("already in") ~= nil, tostring(err_dupname))

for _, evil in ipairs({ ".", "..", ".dot", "a/b", "a\\b" }) do
	check("add_entry rejects member name " .. string.format("%q", evil), workspace.add_entry(named, { agent = "Bob", name = evil }, cwd) == false)
end
assert_eq("same agent twice under a different session name", workspace.add_entry(named, { agent = "Alice", name = "Alice-2" }, cwd), true)
assert_eq("add Bob", workspace.add_entry(named, { agent = "Bob" }, cwd), true)
on_disk = workspace.read("feature-dev", cwd)
assert_eq("three members persisted", #on_disk.agents, 3)
local e2 = workspace.find_entry(on_disk, "Alice-2")
check("find_entry returns the entry + agent", e2 ~= nil and e2.agent == "Alice")

assert_eq("remove Alice-2", workspace.remove_entry(named, "Alice-2", cwd), true)
on_disk = workspace.read("feature-dev", cwd)
assert_eq("remove persisted immediately", #on_disk.agents, 2)
check("remove of non-member fails", workspace.remove_entry(named, "Alice-2", cwd) == false)

-- ---------------------------------------------------------------------------
-- 3b. Per-workspace overrides: workspaces/<ws>/<session>/<file>
-- ---------------------------------------------------------------------------

local ov_ws = "feature-dev"
assert_eq(
	"override_dir = workspaces/<ws>/<session>",
	workspace.override_dir(ov_ws, "Alice", cwd),
	cwd .. "/.nvim-agent/workspaces/feature-dev/Alice"
)
assert_eq("no overrides initially", #workspace.list_overrides(ov_ws, "Alice", cwd), 0)
check("write_override rejects a non-agent file", workspace.write_override(ov_ws, "Alice", "evil.sh", "x", cwd) == false)

-- Copy-on-first-edit: the override starts as the session's current content.
local fake_active = sandbox .. "/fake-active"
write(fake_active .. "/user_notes.md", "global notes + my project note\n")
assert_eq("copy_override_from", workspace.copy_override_from(ov_ws, "Alice", "user_notes.md", fake_active .. "/user_notes.md", cwd), true)
assert_eq("override file written", read(workspace.override_path(ov_ws, "Alice", "user_notes.md", cwd)), "global notes + my project note\n")
assert_eq("write_override", workspace.write_override(ov_ws, "Alice", "role.md", "project role\n", cwd), true)
local listed_ov = workspace.list_overrides(ov_ws, "Alice", cwd)
check("list_overrides in AGENT_FILES order", #listed_ov == 2 and listed_ov[1] == "role.md" and listed_ov[2] == "user_notes.md", table.concat(listed_ov, ","))

-- apply_overrides lays overrides over a dir holding the global files.
local target = sandbox .. "/apply-target"
write(target .. "/role.md", "GLOBAL ROLE\n")
write(target .. "/user_notes.md", "GLOBAL NOTES\n")
write(target .. "/system_prompt.md", "GLOBAL PROMPT")
local applied = workspace.apply_overrides(ov_ws, "Alice", target, cwd)
check("apply_overrides returns the applied files", #applied == 2)
assert_eq("overridden role wins", read(target .. "/role.md"), "project role\n")
assert_eq("overridden notes win", read(target .. "/user_notes.md"), "global notes + my project note\n")
assert_eq("non-overridden file untouched", read(target .. "/system_prompt.md"), "GLOBAL PROMPT")

-- Overrides are keyed by SESSION name: a second copy of the agent has its own.
assert_eq("other member has no overrides", #workspace.list_overrides(ov_ws, "Bob", cwd), 0)

-- clear one → the other remains; clear all → dir gone.
workspace.clear_overrides(ov_ws, "Alice", "role.md", cwd)
local after_one = workspace.list_overrides(ov_ws, "Alice", cwd)
check("clear one override leaves the rest", #after_one == 1 and after_one[1] == "user_notes.md")
workspace.clear_overrides(ov_ws, "Alice", nil, cwd)
check("clear all removes the override dir", vim.fn.isdirectory(workspace.override_dir(ov_ws, "Alice", cwd)) == 0)
check("clearing the last single override removes the dir too", (function()
	workspace.write_override(ov_ws, "Alice", "role.md", "r\n", cwd)
	workspace.clear_overrides(ov_ws, "Alice", "role.md", cwd)
	return vim.fn.isdirectory(workspace.override_dir(ov_ws, "Alice", cwd)) == 0
end)())

-- clear_overrides refuses non-agent files and bad member names (it deletes).
workspace.write_override(ov_ws, "Alice", "role.md", "r\n", cwd)
workspace.clear_overrides(ov_ws, "Alice", "../workspace.json", cwd)
check("clear_overrides ignores a non-agent file", workspace.exists(ov_ws, cwd))
workspace.clear_overrides(ov_ws, "..", nil, cwd)
check("clear_overrides ignores a traversal member name", vim.fn.isdirectory(cwd .. "/.nvim-agent/workspaces") == 1 and workspace.exists(ov_ws, cwd))
workspace.clear_overrides(ov_ws, "Alice", nil, cwd)

-- remove_entry deletes the member's overrides.
workspace.write_override(ov_ws, "Bob", "user_notes.md", "bob notes\n", cwd)
check("setup: Bob has an override", #workspace.list_overrides(ov_ws, "Bob", cwd) == 1)
workspace.remove_entry(named, "Bob", cwd)
check("remove_entry deletes the member's overrides", vim.fn.isdirectory(workspace.override_dir(ov_ws, "Bob", cwd)) == 0)
workspace.add_entry(named, { agent = "Bob" }, cwd)

-- The ephemeral workspace supports overrides exactly like a named one.
workspace.write_override(workspace.EPHEMERAL, "Bob", "persistent_dirs.json", '[{"tag":"x","path":"/x"}]', cwd)
check("ephemeral workspace holds overrides", read(cwd .. "/.nvim-agent/workspaces/ephemeral/Bob/persistent_dirs.json") ~= nil)
check("ephemeral overrides listed", #workspace.list_overrides(workspace.EPHEMERAL, "Bob", cwd) == 1)

-- ---------------------------------------------------------------------------
-- 4. Current workspace, rename (promote ephemeral), delete
-- ---------------------------------------------------------------------------

workspace.set_current(eph)
assert_eq("get_current", workspace.get_current(), eph)
workspace.add_entry(eph, { agent = "Bob" }, cwd)

check("rename to existing fails", workspace.rename("ephemeral", "feature-dev", cwd) == false)
check("rename to reserved fails", workspace.rename("feature-dev", "ephemeral", cwd) == false)
assert_eq("promote ephemeral → 'sprint-1'", workspace.rename("ephemeral", "sprint-1", cwd), true)
check("old dir gone", vim.fn.isdirectory(cwd .. "/.nvim-agent/workspaces/ephemeral") == 0)
check("overrides travel with the renamed workspace", #workspace.list_overrides("sprint-1", "Bob", cwd) == 1)
local promoted = workspace.read("sprint-1", cwd)
check("promoted manifest keeps members and has new name", promoted and promoted.name == "sprint-1" and #promoted.agents == 1)
assert_eq("current manifest renamed in place", workspace.get_current().name, "sprint-1")
check("exists('ephemeral') false after promotion", workspace.exists("ephemeral", cwd) == false)

assert_eq("delete aaa", workspace.delete("aaa-first-alphabetically", cwd), true)
check("delete missing fails", workspace.delete("aaa-first-alphabetically", cwd) == false)
assert_eq("delete current clears current", (function()
	workspace.delete("sprint-1", cwd)
	return workspace.get_current()
end)(), nil)

-- ---------------------------------------------------------------------------
-- 5. Sessions: create(name, agent); liveness is separate from membership
-- ---------------------------------------------------------------------------

check("create without agent fails", select(1, session.create("x", nil)) == nil)
check("create rejects traversal session name", select(1, session.create("..", "Alice")) == nil)
check("session records its project cwd", (function()
	local s = session.create("CwdCheck", "Alice", "/some/project")
	local ok = s and s.cwd == "/some/project"
	if s then
		session.close(s.id)
	end
	return ok
end)())
local s1 = session.create("Alice", "Alice")
check("session created", s1 ~= nil and s1.name == "Alice" and s1.agent == "Alice")
assert_eq("initial state", s1.state, "created")
check("active_dir under sessions/<instance_id>/<name>/active", s1.active_dir == base_dir .. "/sessions/" .. session.instance_id .. "/Alice/active")
check("duplicate session name rejected", select(1, session.create("Alice", "Bob")) == nil)
local s2 = session.create("Alice-2", "Alice")
check("same agent, different session name is fine", s2 ~= nil and s2.agent == "Alice")
assert_eq("get_by_active_dir", session.get_by_active_dir(s2.active_dir), s2)
check("is_running false before launch", session.is_running(s1) == false)

s1.jobid = 4242
check("is_running true with a job", session.is_running(s1) == true)
session.mark_exited(s1.id, 1)
assert_eq("mark_exited sets state", s1.state, "exited")
check("mark_exited clears job", s1.jobid == nil)
check("exited session is still registered (membership kept)", session.get_by_name("Alice") == s1)

session.close(s2.id)
check("close drops the session", session.get_by_name("Alice-2") == nil)
check("close of other session leaves s1", session.get_by_name("Alice") == s1)
session.close(s1.id)

-- ---------------------------------------------------------------------------
-- Cleanup + summary
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
