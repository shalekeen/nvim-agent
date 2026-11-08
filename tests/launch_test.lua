-- End-to-end launch-path test with a stub adapter whose "CLI" is `sleep`.
-- Run with: nvim -l tests/launch_test.lua
--
-- Exercises the parts no unit test reaches: setup → spawn (define + add +
-- launch via termopen) → status file → manifest auto-save → CLI exit marks
-- the session exited but keeps membership → relaunch into the same session
-- (new terminal buffer, same active_dir) → adding a library agent by name →
-- remove. Everything runs against a sandbox base_dir and cwd.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end
plugin_root = vim.fn.fnamemodify(plugin_root, ":p"):gsub("/$", "")
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
		print("FAIL " .. label .. (detail and (" — " .. tostring(detail)) or ""))
		fail_count = fail_count + 1
	end
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

-- ---------------------------------------------------------------------------
-- Sandbox: project cwd + base_dir, and a stub adapter that just sleeps.
-- ---------------------------------------------------------------------------

local sandbox = vim.fn.tempname()
local cwd = sandbox .. "/proj"
vim.fn.mkdir(cwd, "p")
vim.cmd("cd " .. vim.fn.fnameescape(cwd))

local stub = {
	get_cmd = function()
		return { "sh", "-c", "sleep 30" }
	end,
}
require("nvim-agent").setup({ adapter = stub, base_dir = sandbox .. "/base", auto_open = false })

local L = require("nvim-agent.launcher")
local S = require("nvim-agent.session")
local W = require("nvim-agent.workspace")
local A = require("nvim-agent.agent")
local status_dir = W.instance_runtime_dir(cwd) .. "/status"

-- ---------------------------------------------------------------------------
-- 1. spawn with no live workspace: defines a spawned agent, creates the
--    ephemeral workspace, adds the member, launches it.
-- ---------------------------------------------------------------------------

local r = L.spawn("helper", "HELPER PROMPT", "helps with things", "")
check("spawn succeeds", r.success, r.error)
check("spawned agent defined under agents/spawned/", vim.fn.isdirectory(sandbox .. "/base/agents/spawned/helper") == 1)
local m = W.get_current()
check("ephemeral workspace became current", m and m.name == W.EPHEMERAL)
local saved = W.read(W.EPHEMERAL, cwd)
check("manifest auto-saved with the member", saved and #saved.agents == 1 and saved.agents[1].agent == "helper")

vim.wait(2000, function()
	local s = S.get_by_name("helper")
	return s ~= nil and s.jobid ~= nil
end)
local sess = S.get_by_name("helper")
check("session exists and is running", sess and S.is_running(sess), sess and sess.state)
check("session state is running", sess and sess.state == "running", sess and sess.state)
check("status file written in this instance's dir", vim.fn.filereadable(status_dir .. "/helper.json") == 1)
check("status file carries the role", (read(status_dir .. "/helper.json") or ""):find("helps with things") ~= nil)
check("active_dir mirrors role.md", read(sess.active_dir .. "/role.md") == "helps with things\n")
check("active_dir mirrors system_prompt.md", read(sess.active_dir .. "/system_prompt.md") == "HELPER PROMPT")
check("terminal buffer named [Agent-<session>: <agent>]", vim.api.nvim_buf_get_name(sess.bufnr):find("%[Agent%-helper: helper%]") ~= nil)
check("statusline", require("nvim-agent").statusline() == "Agent-helper: helper @ ephemeral", require("nvim-agent").statusline())

-- ---------------------------------------------------------------------------
-- 2. spawn again while running → refused
-- ---------------------------------------------------------------------------

local r2 = L.spawn("helper", "", "", "")
check("spawn of a running agent is refused", not r2.success and r2.error:find("already running") ~= nil, r2.error)

-- ---------------------------------------------------------------------------
-- 3. CLI exits → exited, status removed, still a member
-- ---------------------------------------------------------------------------

local first_bufnr = sess.bufnr
vim.fn.jobstop(sess.jobid)
vim.wait(3000, function()
	return sess.state == "exited"
end)
check("session marked exited", sess.state == "exited", sess.state)
check("job cleared", sess.jobid == nil)
check("status file removed on exit", vim.fn.filereadable(status_dir .. "/helper.json") == 0)
check("still registered", S.get_by_name("helper") == sess)
check("still a workspace member", W.find_entry(W.get_current(), "helper") ~= nil)
check("statusline shows (exited)", require("nvim-agent").statusline():find("%(exited%)") ~= nil)

-- ---------------------------------------------------------------------------
-- 4. spawn by name relaunches into the SAME session (new buffer, same dir)
-- ---------------------------------------------------------------------------

local r3 = L.spawn("helper", "", "", "")
check("spawn relaunches an exited agent", r3.success and r3.relaunched, r3.error)
vim.wait(2000, function()
	return sess.jobid ~= nil
end)
check("relaunched into the same session object", S.get_by_name("helper") == sess and S.is_running(sess))
check("relaunch got a fresh terminal buffer", sess.bufnr ~= nil and sess.bufnr ~= first_bufnr)
check("old dead buffer was deleted", not vim.api.nvim_buf_is_valid(first_bufnr))
check("fresh buffer carries the [Agent-…] name", vim.api.nvim_buf_get_name(sess.bufnr):find("%[Agent%-helper: helper%]") ~= nil)
check("status file back after relaunch", vim.fn.filereadable(status_dir .. "/helper.json") == 1)

-- terminal.open on a running session must not relaunch.
local job_before = sess.jobid
require("nvim-agent.terminal").open(sess.id)
check("open on a running session keeps its job", sess.jobid == job_before)

-- ---------------------------------------------------------------------------
-- 5. library agent added by name via spawn (no prompt/role needed)
-- ---------------------------------------------------------------------------

A.create("lib-agent", { role = "from library" })
local r4 = L.spawn("lib-agent", "", "", "")
check("spawn adds an existing library agent without prompt/role", r4.success, r4.error)
check("library agent not duplicated into spawned/", vim.fn.isdirectory(sandbox .. "/base/agents/spawned/lib-agent") == 0)
check("two members now", #W.get_current().agents == 2)
vim.wait(2000, function()
	local s = S.get_by_name("lib-agent")
	return s ~= nil and s.jobid ~= nil
end)
check("library agent running", S.is_running(S.get_by_name("lib-agent")))

-- ---------------------------------------------------------------------------
-- 6. remove → session gone, status gone, manifest updated
-- ---------------------------------------------------------------------------

L.remove_agent("helper", cwd)
check("remove drops the session", S.get_by_name("helper") == nil)
check("remove deletes the status file", vim.fn.filereadable(status_dir .. "/helper.json") == 0)
check("remove persists to the manifest", #(W.read(W.EPHEMERAL, cwd).agents) == 1)
check("remove of a non-member is harmless", (function()
	L.remove_agent("nobody", cwd)
	return #(W.read(W.EPHEMERAL, cwd).agents) == 1
end)())

-- ---------------------------------------------------------------------------
-- 7. unknown name without prompt/role → clear error, nothing created
-- ---------------------------------------------------------------------------

local r5 = L.spawn("nobody", "", "", "")
check("spawn of an unknown agent without prompt/role errors", not r5.success and r5.error:find("required") ~= nil, r5.error)
check("nothing was defined for it", not A.exists("nobody"))
check("nothing was added for it", W.find_entry(W.get_current(), "nobody") == nil)

-- ---------------------------------------------------------------------------
-- Cleanup + summary
-- ---------------------------------------------------------------------------

for _, s in ipairs(S.list()) do
	S.close(s.id)
end
vim.cmd("cd " .. vim.fn.fnameescape(plugin_root))
vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
