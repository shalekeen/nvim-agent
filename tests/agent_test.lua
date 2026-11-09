-- Global agent library tests.
-- Run with: nvim -l tests/agent_test.lua
--
-- Covers ~/.nvim-agent/agents/: create (role mandatory), the spawned
-- section, resolution order, copy, load/save mirroring, and delete.

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
check("config.json seeded with defaults", vim.deep_equal(vim.json.decode(read(base_dir .. "/agents/Alice/config.json")), agent.DEFAULT_CONFIG))
check("AGENT_FILES includes config.json", vim.tbl_contains(agent.AGENT_FILES, "config.json"))

-- read_config: defaults, partial, invalid, garbage, missing.
local cfg_dir = sandbox .. "/cfg"
vim.fn.mkdir(cfg_dir, "p")
check("read_config on a missing file gives defaults", vim.deep_equal(agent.read_config(cfg_dir), agent.DEFAULT_CONFIG))
write(cfg_dir .. "/config.json", '{"inbox_wakeups": false}')
local c1 = agent.read_config(cfg_dir)
check("read_config applies a partial file over defaults", c1.inbox_wakeups == false and c1.history == "persistent" and c1.inbox_wakeup_interval == 30)
check("default interval is 30 s and wakeups default on", agent.DEFAULT_CONFIG.inbox_wakeup_interval == 30 and agent.DEFAULT_CONFIG.inbox_wakeups == true)
write(cfg_dir .. "/config.json", '{"inbox_wakeup_interval": 300}')
check("read_config accepts a custom interval", agent.read_config(cfg_dir).inbox_wakeup_interval == 300)
write(cfg_dir .. "/config.json", '{"inbox_wakeup_interval": 7.9}')
check("read_config floors a fractional interval", agent.read_config(cfg_dir).inbox_wakeup_interval == 7)
for _, bad in ipairs({ '"30"', "0", "-5", "2", "true" }) do
	write(cfg_dir .. "/config.json", '{"inbox_wakeup_interval": ' .. bad .. "}")
	check("read_config rejects interval " .. bad .. " (falls back to 30)", agent.read_config(cfg_dir).inbox_wakeup_interval == 30)
end
check("default periodic is empty", #agent.DEFAULT_CONFIG.periodic == 0)
write(cfg_dir .. "/config.json", '{"periodic": [{"prompt": "status?", "interval": 600}, {"prompt": "run tests", "interval": 60.7, "when": "always"}]}')
local per = agent.read_config(cfg_dir).periodic
check("read_config parses periodic entries", #per == 2 and per[1].prompt == "status?" and per[1].interval == 600 and per[1].when == "idle", vim.inspect(per))
check("read_config floors periodic interval and keeps when=always", per[2].interval == 60 and per[2].when == "always")
write(cfg_dir .. "/config.json", '{"periodic": [{"prompt": "", "interval": 60}, {"prompt": "x", "interval": 2}, {"prompt": "y"}, {"interval": 60}, "junk", {"prompt": "ok", "interval": 30, "when": "sometimes"}]}')
per = agent.read_config(cfg_dir).periodic
check("read_config drops invalid periodic entries and normalises when", #per == 1 and per[1].prompt == "ok" and per[1].when == "idle", vim.inspect(per))
write(cfg_dir .. "/config.json", '{"periodic": "nope"}')
check("read_config ignores a non-array periodic", #agent.read_config(cfg_dir).periodic == 0)
write(cfg_dir .. "/config.json", '{"inbox_wakeups": "nope", "history": "weekly", "extra": 1}')
check("read_config ignores invalid values and unknown keys", vim.deep_equal(agent.read_config(cfg_dir), agent.DEFAULT_CONFIG))
write(cfg_dir .. "/config.json", '{"history": "fresh"}')
check("read_config accepts history=fresh", agent.read_config(cfg_dir).history == "fresh")
write(cfg_dir .. "/config.json", "{not json")
check("read_config survives garbage", vim.deep_equal(agent.read_config(cfg_dir), agent.DEFAULT_CONFIG))
check("read_config(nil) gives defaults", vim.deep_equal(agent.read_config(nil), agent.DEFAULT_CONFIG))

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

-- If both exist on disk (created by hand), the user agent wins resolution.
vim.fn.mkdir(base_dir .. "/agents/spawned/Bob", "p")
write(base_dir .. "/agents/spawned/Bob/role.md", "impostor\n")
local bdir, bspawned = agent.resolve("Bob")
check("user agent shadows spawned of same name", bdir == base_dir .. "/agents/Bob" and bspawned == false)
vim.fn.delete(base_dir .. "/agents/spawned/Bob", "rf")

-- ---------------------------------------------------------------------------
-- 4. Copy: always lands as a user agent, carries every file
-- ---------------------------------------------------------------------------

write(base_dir .. "/agents/Alice/permissions.json", '{"profile":"oversight"}')
assert_eq("copy Alice → Alice-proj", agent.copy("Alice", "Alice-proj"), true)
assert_eq("copy carries role", read(base_dir .. "/agents/Alice-proj/role.md"), "lead implementer\n")
assert_eq("copy carries prompt", read(base_dir .. "/agents/Alice-proj/system_prompt.md"), "DEFAULT_PROMPT")
assert_eq("copy carries permissions", read(base_dir .. "/agents/Alice-proj/permissions.json"), '{"profile":"oversight"}')
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
assert_eq("load copied permissions", read(active .. "/permissions.json"), '{"profile":"oversight"}')
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
-- Cleanup + summary
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
