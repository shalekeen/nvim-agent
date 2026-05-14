-- Tests for lua/nvim-agent/flavor/last.lua.
-- Run with: nvim -l tests/flavor_last_test.lua
--
-- Pins down the cross-restart contract AND the per-cwd scoping that
-- prevents two simultaneously-running Neovim instances in different
-- projects from trampling each other's "last used flavor" memory.

-- ---------------------------------------------------------------------------
-- Bootstrapping (mirrors tests/workspace_test.lua).
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Test sandbox: temp ~/.nvim-agent equivalent.
-- ---------------------------------------------------------------------------

local sandbox = vim.fn.tempname()
local base_dir = sandbox .. "/dot-nvim-agent"
vim.fn.mkdir(base_dir, "p")

local config = require("nvim-agent.config")
config.setup({ base_dir = base_dir })

local last = require("nvim-agent.flavor.last")

-- ---------------------------------------------------------------------------
-- 1. Path scheme: persistence lives under base_dir/last_flavor/<sanitized>.json
-- ---------------------------------------------------------------------------

local cwd_a = "/home/user/project-a"
local cwd_b = "/home/user/project-b"

local path_a = last.path(cwd_a)
local path_b = last.path(cwd_b)

check("path() returns under base_dir/last_flavor/", path_a:find(base_dir .. "/last_flavor/", 1, true) == 1)
check(".json suffix on path", path_a:sub(-5) == ".json")
check("different cwds → different paths", path_a ~= path_b)
check("path is deterministic across calls", last.path(cwd_a) == path_a)

-- Sanitization: slashes become underscores.
check("path contains sanitized cwd", path_a:find("_home_user_project-a", 1, true) ~= nil, "got " .. path_a)
check("hyphens preserved in sanitized cwd (not replaced)", path_a:find("project-a", 1, true) ~= nil)

-- ---------------------------------------------------------------------------
-- 2. Round-trip: persist then read for the same cwd.
-- ---------------------------------------------------------------------------

last.persist(cwd_a, "agent", "v1")
local f, cp = last.read(cwd_a)
assert_eq("read returns persisted flavor", f, "agent")
assert_eq("read returns persisted checkpoint", cp, "v1")

-- Persisting WITHOUT a checkpoint stores nil and round-trips as nil.
last.persist(cwd_a, "research", nil)
local f2, cp2 = last.read(cwd_a)
assert_eq("read returns updated flavor", f2, "research")
check("nil checkpoint round-trips as nil", cp2 == nil or cp2 == vim.NIL)

-- ---------------------------------------------------------------------------
-- 3. THE BUG: different cwds MUST NOT share state.
-- ---------------------------------------------------------------------------

-- After step 2, cwd_a has "research/nil" persisted. cwd_b has nothing.
local f_b, cp_b = last.read(cwd_b)
check("cwd_b read returns nil before any write", f_b == nil and cp_b == nil)

-- Now persist a different flavor under cwd_b. cwd_a must remain untouched.
last.persist(cwd_b, "writer", "draft")
local f_a_after, cp_a_after = last.read(cwd_a)
assert_eq("cwd_a flavor untouched by cwd_b write", f_a_after, "research")
check("cwd_a checkpoint untouched by cwd_b write", cp_a_after == nil or cp_a_after == vim.NIL)

local f_b_after, cp_b_after = last.read(cwd_b)
assert_eq("cwd_b flavor was actually written", f_b_after, "writer")
assert_eq("cwd_b checkpoint was actually written", cp_b_after, "draft")

-- Overwriting cwd_b doesn't affect cwd_a either.
last.persist(cwd_b, "reviewer", "v2")
local f_a3, _ = last.read(cwd_a)
assert_eq("cwd_a still untouched after second cwd_b write", f_a3, "research")

-- ---------------------------------------------------------------------------
-- 4. Missing-file / corruption tolerance.
-- ---------------------------------------------------------------------------

local cwd_missing = "/never/persisted/here"
local f_m, cp_m = last.read(cwd_missing)
check("read() on missing file returns nil,nil", f_m == nil and cp_m == nil)

-- Write garbage and confirm read() doesn't throw.
local garbage_path = last.path("/garbage/cwd")
vim.fn.mkdir(vim.fn.fnamemodify(garbage_path, ":h"), "p")
local fh = io.open(garbage_path, "w")
fh:write("{not valid json")
fh:close()
local f_g, cp_g = last.read("/garbage/cwd")
check("read() on corrupt JSON returns nil,nil (no throw)", f_g == nil and cp_g == nil)

-- ---------------------------------------------------------------------------
-- 5. Default cwd resolution.
-- ---------------------------------------------------------------------------

-- path(nil) and path() should both fall back to vim.fn.getcwd().
local current_cwd = vim.fn.getcwd()
assert_eq("path(nil) defaults to vim.fn.getcwd()", last.path(nil), last.path(current_cwd))
assert_eq("path() with no arg defaults to vim.fn.getcwd()", last.path(), last.path(current_cwd))

-- ---------------------------------------------------------------------------
-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
