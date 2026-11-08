-- Global agent library tests.
-- Run with: nvim -l tests/agent_test.lua
--
-- Covers ~/.nvim-agent/agents/: create (role mandatory), the spawned
-- section, resolution order, copy, load/save mirroring, delete, and the
-- one-time migration of legacy flavors + agent_templates.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(plugin_root)

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
local base_dir = sandbox .. "/dot-nvim-agent"
vim.fn.mkdir(base_dir, "p")

local config = require("nvim-agent.config")
config.setup({ base_dir = base_dir, default_system_prompt = "DEFAULT_PROMPT" })
local agent = require("nvim-agent.agent")

-- ---------------------------------------------------------------------------
-- 1. Create: role is mandatory, defaults are seeded, layout is agents/<name>/
-- ---------------------------------------------------------------------------

local ok_norole, err_norole = agent.create("NoRole", {})
check("create without role fails", not ok_norole and err_norole:find("role") ~= nil, tostring(err_norole))
check("create without role leaves no dir", vim.fn.isdirectory(base_dir .. "/agents/NoRole") == 0)

assert_eq("create('Alice') ok", agent.create("Alice", { role = "lead implementer" }), true)
check("agent dir is agents/<name>/", vim.fn.isdirectory(base_dir .. "/agents/Alice") == 1)
assert_eq("role.md written (trailing newline)", read(base_dir .. "/agents/Alice/role.md"), "lead implementer\n")
assert_eq("system_prompt.md seeded from default_system_prompt", read(base_dir .. "/agents/Alice/system_prompt.md"), "DEFAULT_PROMPT")
check("user_notes.md seeded", (read(base_dir .. "/agents/Alice/user_notes.md") or ""):find("User Notes") ~= nil)
assert_eq("persistent_dirs.json seeded", read(base_dir .. "/agents/Alice/persistent_dirs.json"), "[]")

local ok_dup, err_dup = agent.create("Alice", { role = "again" })
check("duplicate create fails", not ok_dup and err_dup:find("already exists") ~= nil, tostring(err_dup))

assert_eq("create with explicit prompt", agent.create("Bob", { role = "reviewer", system_prompt = "BOB" }), true)
assert_eq("explicit prompt kept", read(base_dir .. "/agents/Bob/system_prompt.md"), "BOB")

assert_eq("exists('Alice')", agent.exists("Alice"), true)
assert_eq("exists('Nope')", agent.exists("Nope"), false)
assert_eq("read_role('Alice') trims", agent.read_role("Alice"), "lead implementer")
check("read_role on missing agent is nil", agent.read_role("Nope") == nil)

-- ---------------------------------------------------------------------------
-- 2. Name validation
-- ---------------------------------------------------------------------------

for _, bad in ipairs({ "", "a/b", "a\\b", ".hidden", "spawned" }) do
	local ok = agent.validate_name(bad)
	check("validate_name rejects " .. string.format("%q", bad), ok == false)
end
check("validate_name accepts 'Senior SWE 1'", agent.validate_name("Senior SWE 1") == true)
check("create with bad name fails", agent.create("x/y", { role = "r" }) == false)

-- ---------------------------------------------------------------------------
-- 3. Spawned section: separate dir, listed after user agents, user shadows
-- ---------------------------------------------------------------------------

assert_eq("create spawned", agent.create("Zed", { role = "spawned helper", spawned = true }), true)
check("spawned lives under agents/spawned/", vim.fn.isdirectory(base_dir .. "/agents/spawned/Zed") == 1)
check("spawned NOT at top level", vim.fn.isdirectory(base_dir .. "/agents/Zed") == 0)
assert_eq("exists() finds spawned", agent.exists("Zed"), true)
local zdir, zspawned = agent.resolve("Zed")
check("resolve returns spawned flag", zdir ~= nil and zspawned == true)

local listed = agent.list()
assert_eq("list has 3 agents", #listed, 3)
assert_eq("list[1] Alice (user)", listed[1].name, "Alice")
assert_eq("list[2] Bob (user)", listed[2].name, "Bob")
assert_eq("list[3] Zed (spawned, last)", listed[3].name, "Zed")
check("list carries spawned flag", listed[1].spawned == false and listed[3].spawned == true)
assert_eq("list carries role", listed[2].role, "reviewer")
check("'spawned' dir itself is not listed as an agent", (function()
	for _, a in ipairs(listed) do
		if a.name == "spawned" then
			return false
		end
	end
	return true
end)())

-- Spawning a name that exists as a user agent is refused.
local ok_shadow, err_shadow = agent.create("Alice", { role = "x", spawned = true })
check("cannot spawn over an existing user agent", not ok_shadow and err_shadow:find("already exists") ~= nil)

-- If both exist on disk (legacy / manual), the user agent wins resolution.
vim.fn.mkdir(base_dir .. "/agents/spawned/Bob", "p")
write(base_dir .. "/agents/spawned/Bob/role.md", "impostor\n")
local bdir, bspawned = agent.resolve("Bob")
check("user agent shadows spawned of same name", bdir == base_dir .. "/agents/Bob" and bspawned == false)
vim.fn.delete(base_dir .. "/agents/spawned/Bob", "rf")

-- ---------------------------------------------------------------------------
-- 4. Copy: always lands as a user agent, carries every file
-- ---------------------------------------------------------------------------

write(base_dir .. "/agents/Alice/permissions.json", '{"profile":"qa"}')
assert_eq("copy Alice → Alice-proj", agent.copy("Alice", "Alice-proj"), true)
assert_eq("copy carries role", read(base_dir .. "/agents/Alice-proj/role.md"), "lead implementer\n")
assert_eq("copy carries prompt", read(base_dir .. "/agents/Alice-proj/system_prompt.md"), "DEFAULT_PROMPT")
assert_eq("copy carries permissions", read(base_dir .. "/agents/Alice-proj/permissions.json"), '{"profile":"qa"}')
check("copy onto existing name fails", agent.copy("Alice", "Bob") == false)
check("copy of missing source fails", agent.copy("Nope", "X") == false)
assert_eq("copy of spawned agent becomes a user agent", agent.copy("Zed", "Zed-adopted"), true)
check("adopted copy at top level", vim.fn.isdirectory(base_dir .. "/agents/Zed-adopted") == 1)

-- ---------------------------------------------------------------------------
-- 5. Load / save: the session active_dir mirrors the agent
-- ---------------------------------------------------------------------------

local active = sandbox .. "/sessions/x/Alice/active"
assert_eq("load Alice into active_dir", agent.load("Alice", active), true)
assert_eq("load copied role", read(active .. "/role.md"), "lead implementer\n")
assert_eq("load copied permissions", read(active .. "/permissions.json"), '{"profile":"qa"}')
check("load of missing agent fails", agent.load("Nope", sandbox .. "/never") == false)

write(active .. "/user_notes.md", "project note\n")
write(active .. "/role.md", "lead implementer, now also reviewer\n")
assert_eq("save active_dir → Alice", agent.save("Alice", active), true)
assert_eq("save wrote notes back", read(base_dir .. "/agents/Alice/user_notes.md"), "project note\n")
assert_eq("save wrote role back", read(base_dir .. "/agents/Alice/role.md"), "lead implementer, now also reviewer\n")
check("save never creates an agent", agent.save("Ghost", active) == false and not agent.exists("Ghost"))

-- ---------------------------------------------------------------------------
-- 6. Delete
-- ---------------------------------------------------------------------------

assert_eq("delete Bob", agent.delete("Bob"), true)
check("Bob gone", not agent.exists("Bob"))
check("delete missing fails", agent.delete("Bob") == false)
assert_eq("delete spawned Zed", agent.delete("Zed"), true)
check("Zed gone from spawned/", vim.fn.isdirectory(base_dir .. "/agents/spawned/Zed") == 0)

-- ---------------------------------------------------------------------------
-- 7. Legacy migration: flavors + templates → agents/, copied not moved,
--    checkpoints ignored, placeholder role where missing, runs once.
-- ---------------------------------------------------------------------------

local legacy_base = sandbox .. "/legacy-base"
vim.fn.mkdir(legacy_base, "p")
config.setup({ base_dir = legacy_base, default_system_prompt = "D" })

-- A flavor with a checkpoint and no role.
write(legacy_base .. "/dev/system_prompt.md", "DEV PROMPT")
write(legacy_base .. "/dev/user_notes.md", "dev notes")
write(legacy_base .. "/dev/persistent_dirs.json", '[{"tag":"src","path":"/src"}]')
write(legacy_base .. "/dev/checkpoints/v2/system_prompt.md", "CHECKPOINT PROMPT")
-- A template with a role.
write(legacy_base .. "/agent_templates/SrSWE/system_prompt.md", "SR PROMPT")
write(legacy_base .. "/agent_templates/SrSWE/role.md", "senior engineer\n")
-- Reserved / non-flavor dirs that must be ignored.
vim.fn.mkdir(legacy_base .. "/sessions/123/main/active", "p")
vim.fn.mkdir(legacy_base .. "/hooks", "p")
vim.fn.mkdir(legacy_base .. "/last_flavor", "p")
vim.fn.mkdir(legacy_base .. "/.cache", "p")
vim.fn.mkdir(legacy_base .. "/random-dir-without-prompt", "p")
-- An agent that already exists in the new layout must be skipped, not clobbered.
agent.create("dev-existing", { role = "pre-existing" })
write(legacy_base .. "/dev-existing/system_prompt.md", "LEGACY SHOULD NOT WIN")

local report = agent.migrate_legacy()
check("migration returns a report", report ~= nil)
check("flavor 'dev' imported", agent.exists("dev"))
assert_eq("imported flavor prompt", read(legacy_base .. "/agents/dev/system_prompt.md"), "DEV PROMPT")
assert_eq("imported flavor dirs", read(legacy_base .. "/agents/dev/persistent_dirs.json"), '[{"tag":"src","path":"/src"}]')
assert_eq("flavor without role gets placeholder", agent.read_role("dev"), agent.placeholder_role("dev"))
check("placeholder reported in needs_role", vim.tbl_contains(report.needs_role, "dev"))
check("checkpoints are NOT imported as agents", not agent.exists("v2") and vim.fn.isdirectory(legacy_base .. "/agents/dev/checkpoints") == 0)
check("template 'SrSWE' imported", agent.exists("SrSWE"))
assert_eq("template role kept", agent.read_role("SrSWE"), "senior engineer")
check("template not in needs_role", not vim.tbl_contains(report.needs_role, "SrSWE"))
check("reserved dirs not imported", not agent.exists("sessions") and not agent.exists("hooks") and not agent.exists("last_flavor"))
check("dir without system_prompt.md not imported", not agent.exists("random-dir-without-prompt"))
assert_eq("existing agent not clobbered", read(legacy_base .. "/agents/dev-existing/system_prompt.md"), "D")
check("existing agent reported as skipped", vim.tbl_contains(report.skipped, "dev-existing"))
check("legacy flavor dir left in place", vim.fn.isdirectory(legacy_base .. "/dev") == 1)
check("legacy template dir left in place", vim.fn.isdirectory(legacy_base .. "/agent_templates/SrSWE") == 1)
check("migration stamp written", vim.fn.filereadable(legacy_base .. "/.agents_migrated") == 1)
check("second migration run is a no-op (nil)", agent.migrate_legacy() == nil)

-- A pristine base dir migrates nothing and reports nil.
local pristine = sandbox .. "/pristine"
vim.fn.mkdir(pristine, "p")
config.setup({ base_dir = pristine })
check("pristine base_dir: migrate_legacy returns nil", agent.migrate_legacy() == nil)

-- ---------------------------------------------------------------------------
-- Cleanup + summary
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
