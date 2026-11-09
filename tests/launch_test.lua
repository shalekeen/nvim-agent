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
-- Buffer name is term://<cwd>//<pid>:<title> so bufferlines show just the title.
local bname = vim.api.nvim_buf_get_name(sess.bufnr)
check("terminal buffer named like a native terminal with the session name as title", bname:match("^term://.*//%d+:helper$") ~= nil, bname)
check("buffer-local vars expose session + agent", vim.b[sess.bufnr].nvim_agent_session == "helper" and vim.b[sess.bufnr].nvim_agent_agent == "helper")
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
check("fresh buffer carries the session-name title", vim.api.nvim_buf_get_name(sess.bufnr):match("//%d+:helper$") ~= nil, vim.api.nvim_buf_get_name(sess.bufnr))
check("status file back after relaunch", vim.fn.filereadable(status_dir .. "/helper.json") == 1)

-- terminal.open on a running session must not relaunch.
local job_before = sess.jobid
require("nvim-agent.terminal").open(sess.id)
check("open on a running session keeps its job", sess.jobid == job_before)

-- ---------------------------------------------------------------------------
-- 4b. Overrides: edits from the live session go to THIS workspace (the
--     ephemeral one here), never to the global agent; relaunch reapplies
--     them; reset drops them; push promotes them.
-- ---------------------------------------------------------------------------

local global_notes_path = sandbox .. "/base/agents/spawned/helper/user_notes.md"
local global_notes_before = read(global_notes_path)
local ov_path = cwd .. "/.nvim-agent/workspaces/ephemeral/helper/user_notes.md"

local nf = io.open(sess.active_dir .. "/user_notes.md", "w")
nf:write("project-specific note\n")
nf:close()
check("sync_session_file succeeds", L.sync_session_file(sess, "user_notes.md", true))
check("override written under workspaces/ephemeral/<session>/", read(ov_path) == "project-specific note\n", tostring(read(ov_path)))
check("global agent untouched by a session edit", read(global_notes_path) == global_notes_before)
check("session records its overrides", sess.overrides and sess.overrides[1] == "user_notes.md")
check("statusline marks overrides with +", require("nvim-agent").statusline():find("helper%+") ~= nil, require("nvim-agent").statusline())

-- Stop (user-requested) → exited but still a member.
L.stop_agent("helper")
vim.wait(3000, function()
	return sess.state == "exited"
end)
check("stop_agent marks the session exited", sess.state == "exited", sess.state)
check("stop_agent keeps membership", W.find_entry(W.get_current(), "helper") ~= nil)

-- Relaunch reloads global + override: the override wins.
nf = io.open(sess.active_dir .. "/user_notes.md", "w")
nf:write("stale mirror content\n")
nf:close()
L.restart_agent("helper", cwd)
vim.wait(2000, function()
	return sess.jobid ~= nil
end)
check("restart_agent relaunches", S.is_running(sess))
-- restart reuses the existing session without reloading files (the mirror
-- is authoritative while the session exists); a fresh session does reload.
S.close(sess.id)
L.restart_agent("helper", cwd)
vim.wait(2000, function()
	local s = S.get_by_name("helper")
	return s ~= nil and s.jobid ~= nil
end)
sess = S.get_by_name("helper")
check("fresh session applies the workspace override over the global", read(sess.active_dir .. "/user_notes.md") == "project-specific note\n", read(sess.active_dir .. "/user_notes.md"))
check("fresh session records overrides", sess.overrides and sess.overrides[1] == "user_notes.md")

-- A file that exists ONLY as an override must disappear from the mirror on
-- reset (the global agent has no permissions.json).
local pf = io.open(sess.active_dir .. "/permissions.json", "w")
pf:write('{"profile":"oversight"}')
pf:close()
L.sync_session_file(sess, "permissions.json", true)
check("setup: permissions override exists", read(cwd .. "/.nvim-agent/workspaces/ephemeral/helper/permissions.json") ~= nil)
L.reset_overrides("helper", "permissions.json", cwd)
check("reset removes an override-only file from the mirror", read(sess.active_dir .. "/permissions.json") == nil)
L.reset_overrides("helper", "../workspace.json", cwd)
check("reset refuses a non-agent file and keeps the manifest", W.read(W.EPHEMERAL, cwd) ~= nil)

-- reset one file → override gone, mirror back to global.
L.reset_overrides("helper", "user_notes.md", cwd)
check("reset removes the override file", read(ov_path) == nil)
check("reset restores the global content in the mirror", read(sess.active_dir .. "/user_notes.md") == global_notes_before)
check("reset clears sess.overrides", sess.overrides == nil)

-- push → global updated, overrides cleared.
nf = io.open(sess.active_dir .. "/user_notes.md", "w")
nf:write("promoted note\n")
nf:close()
L.sync_session_file(sess, "user_notes.md", true)
check("setup: override exists before push", read(ov_path) == "promoted note\n")
L.push_agent("helper", cwd)
check("push writes the global agent", read(global_notes_path) == "promoted note\n", read(global_notes_path))
check("push clears the workspace override", read(ov_path) == nil)
check("push clears sess.overrides", sess.overrides == nil)

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
-- 4c. Agent runtime config: inbox_wakeups is read live from the mirror;
--     history="fresh" truncates the work log on every launch.
-- ---------------------------------------------------------------------------

check("default config: wakeups on, history persistent", S.config(sess).inbox_wakeups == true and S.config(sess).history == "persistent")
local cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"inbox_wakeups": false, "history": "fresh"}')
cf:close()
check("config edit in the mirror is read live", S.config(sess).inbox_wakeups == false and S.config(sess).history == "fresh")

-- Wakeup evaluation with a fake clock (the real timer ticks every 5 s).
local AC = require("nvim-agent.autocmds")
check("evaluate_wakeup: disabled when inbox_wakeups=false", AC.evaluate_wakeup(sess, 0) == "disabled")
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"inbox_wakeups": true, "inbox_wakeup_interval": 300}')
cf:close()
local trig_dir = W.instance_runtime_dir(cwd) .. "/triggers"
vim.fn.mkdir(trig_dir, "p")
local trig = io.open(trig_dir .. "/helper.md", "w")
trig:write("[x] Triggered\n")
trig:close()
check("evaluate_wakeup: first observation is a baseline", AC.evaluate_wakeup(sess, 0) == "baseline")
check("evaluate_wakeup: 30 s later is still waiting on a 300 s interval", AC.evaluate_wakeup(sess, 30 * 1000) == "waiting")
check("evaluate_wakeup: 299 s later is still waiting", AC.evaluate_wakeup(sess, 299 * 1000) == "waiting")
local r_due = AC.evaluate_wakeup(sess, 300 * 1000)
check("evaluate_wakeup: at 300 s, idle + pending trigger → nudged", r_due == "nudged", r_due)
check("nudge consumed the trigger file", vim.fn.getfsize(trig_dir .. "/helper.md") == 0)
check("evaluate_wakeup: next period with nothing pending → quiet", AC.evaluate_wakeup(sess, 600 * 1000) == "quiet")
-- Output during the interval counts as active, no nudge even if pending.
trig = io.open(trig_dir .. "/helper.md", "w")
trig:write("[y] Triggered\n")
trig:close()
check("evaluate_wakeup: terminal output during the interval → active, not nudged", (function()
	-- Terminal buffers can't be edited from Lua, so simulate "the terminal
	-- printed something" by making the stored tick differ from the live one.
	AC._wake_state[sess.id].tick = -1
	return AC.evaluate_wakeup(sess, 900 * 1000) == "active"
end)())
check("evaluate_wakeup: inactive session", AC.evaluate_wakeup({ id = "ghost", name = "ghost", active_dir = sess.active_dir }, 0) == "inactive")
-- Shorter interval changes cadence live.
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"inbox_wakeups": true, "inbox_wakeup_interval": 5}')
cf:close()
check("evaluate_wakeup: a 5 s interval is due after 5 s", AC.evaluate_wakeup(sess, 905 * 1000) ~= "waiting")
os.remove(trig_dir .. "/helper.md")

-- Periodic prompts, driven with the same fake clock. Each entry has its own
-- clock; "idle" entries skip a period in which the terminal produced output.
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"periodic": [{"prompt": "status?", "interval": 60}, {"prompt": "run tests", "interval": 120, "when": "always"}]}')
cf:close()
local function fired_prompts(list)
	local out = {}
	for _, f in ipairs(list) do
		table.insert(out, f.prompt)
	end
	return table.concat(out, ",")
end
check("periodic: first observation only baselines", #AC.evaluate_periodic(sess, 0) == 0)
check("periodic: nothing due at 30 s", #AC.evaluate_periodic(sess, 30 * 1000) == 0)
check("periodic: 60 s entry fires at 60 s (idle), 120 s entry not yet", fired_prompts(AC.evaluate_periodic(sess, 60 * 1000)) == "status?")
check("periodic: at 120 s both are due", fired_prompts(AC.evaluate_periodic(sess, 120 * 1000)) == "status?,run tests")
-- Simulate terminal output during the next period: the idle entry skips,
-- the always entry still fires.
AC._periodic_state[sess.id]["60\0status?"].tick = -1
AC._periodic_state[sess.id]["120\0run tests"].tick = -1
check("periodic: idle entry skips an active period, always entry fires", fired_prompts(AC.evaluate_periodic(sess, 240 * 1000)) == "run tests")
check("periodic: idle entry fires again once quiet", fired_prompts(AC.evaluate_periodic(sess, 300 * 1000)) == "status?")
-- Removing an entry from the config forgets its clock; adding one baselines.
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"periodic": [{"prompt": "new one", "interval": 60}]}')
cf:close()
check("periodic: config change drops old clocks and baselines the new entry", #AC.evaluate_periodic(sess, 360 * 1000) == 0 and AC._periodic_state[sess.id]["60\0status?"] == nil)
check("periodic: new entry fires after its interval", fired_prompts(AC.evaluate_periodic(sess, 420 * 1000)) == "new one")
check("periodic: inactive session fires nothing", #AC.evaluate_periodic({ id = "ghost", name = "ghost", active_dir = sess.active_dir }, 0) == 0)
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write("{}")
cf:close()
check("periodic: empty config clears state", #AC.evaluate_periodic(sess, 480 * 1000) == 0 and AC._periodic_state[sess.id] == nil)
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"inbox_wakeups": false, "history": "fresh"}')
cf:close()
L.sync_session_file(sess, "config.json", true)
check("config.json is saved as a workspace override", read(cwd .. "/.nvim-agent/workspaces/ephemeral/helper/config.json") ~= nil)

-- history=fresh: the agent's vault notes are wiped when the CLI (re)launches.
local hist_path = W.instance_runtime_dir(cwd) .. "/history/agents/helper/" .. os.date("%Y-%m-%d") .. "/10-00-old-work.md"
vim.fn.mkdir(vim.fn.fnamemodify(hist_path, ":h"), "p")
local hf = io.open(hist_path, "w")
hf:write("old work\n")
hf:close()
L.stop_agent("helper")
vim.wait(3000, function()
	return sess.state == "exited"
end)
L.restart_agent("helper", cwd)
vim.wait(2000, function()
	return sess.jobid ~= nil
end)
check("history=fresh wipes the work log on relaunch", read(hist_path) == nil)

-- history=persistent keeps it.
cf = io.open(sess.active_dir .. "/config.json", "w")
cf:write('{"inbox_wakeups": true, "history": "persistent"}')
cf:close()
L.sync_session_file(sess, "config.json", true)
vim.fn.mkdir(vim.fn.fnamemodify(hist_path, ":h"), "p")
hf = io.open(hist_path, "w")
hf:write("kept work\n")
hf:close()
L.stop_agent("helper")
vim.wait(3000, function()
	return sess.state == "exited"
end)
L.restart_agent("helper", cwd)
vim.wait(2000, function()
	return sess.jobid ~= nil
end)
check("history=persistent keeps the work log across relaunch", read(hist_path) == "kept work\n")
L.reset_overrides("helper", "config.json", cwd)

-- ---------------------------------------------------------------------------
-- 5b. show_all / hide_all arrange and hide existing terminals without
--     launching or stopping anything.
-- ---------------------------------------------------------------------------

local T = require("nvim-agent.terminal")
local jobs_before = {}
for _, s in ipairs(S.list()) do
	jobs_before[s.name] = s.jobid
end
local tabs_before = #vim.api.nvim_list_tabpages()
local shown = T.arrange_all(4)
check("arrange_all arranges every running session", shown == 2, shown)
check("arrange_all assigns windows", S.get_by_name("helper").winnr ~= nil and S.get_by_name("lib-agent").winnr ~= nil)
check("arrange_all launches nothing new", S.get_by_name("helper").jobid == jobs_before["helper"] and S.get_by_name("lib-agent").jobid == jobs_before["lib-agent"])
check("arrange_all opened one agents tab", #vim.api.nvim_list_tabpages() == tabs_before + 1 and T.grid_tab ~= nil)
local grid_wins = vim.api.nvim_tabpage_list_wins(T.grid_tab)
check("agents tab holds exactly the running sessions' windows", #grid_wins == 2)
check("grid windows are equalised (same width)", math.abs(vim.api.nvim_win_get_width(grid_wins[1]) - vim.api.nvim_win_get_width(grid_wins[2])) <= 1)
-- Repeat re-flows in place: no new tab.
T.arrange_all(4)
check("arrange_all reuses the agents tab on repeat", #vim.api.nvim_list_tabpages() == tabs_before + 1)
check("still exactly the running sessions' windows after repeat", #vim.api.nvim_tabpage_list_wins(T.grid_tab) == 2)
-- Column cap: with cols=1 the two agents stack into two rows (same width, half height).
T.arrange_all(1)
local stacked = vim.api.nvim_tabpage_list_wins(T.grid_tab)
local r1, r2 = vim.api.nvim_win_get_position(stacked[1])[1], vim.api.nvim_win_get_position(stacked[2])[1]
check("column cap respected (cols=1 → one per row, stacked vertically)", #stacked == 2 and vim.api.nvim_win_get_width(stacked[1]) == vim.api.nvim_win_get_width(stacked[2]) and r1 ~= r2, string.format("rows %s/%s", tostring(r1), tostring(r2)))
check("show_all alias still works", T.show_all(4) == 2)
local hidden = T.hide_all()
check("hide_all hides at least the grid windows", hidden >= 2, hidden)
check("hide_all forgets the agents tab once it is closed", T.grid_tab == nil)
check("hide_all keeps processes running", S.is_running(S.get_by_name("helper")) and S.is_running(S.get_by_name("lib-agent")))
check("hide_all clears winnr", S.get_by_name("helper").winnr == nil)

-- remove_entry must also drop overrides for the member.
L.sync_session_file(S.get_by_name("helper"), "role.md", true)
check("setup: helper has an override before remove", vim.fn.isdirectory(cwd .. "/.nvim-agent/workspaces/ephemeral/helper") == 1)

-- ---------------------------------------------------------------------------
-- 6. remove → session gone, status gone, manifest updated
-- ---------------------------------------------------------------------------

L.remove_agent("helper", cwd)
check("remove drops the session", S.get_by_name("helper") == nil)
check("remove deletes the status file", vim.fn.filereadable(status_dir .. "/helper.json") == 0)
check("remove persists to the manifest", #(W.read(W.EPHEMERAL, cwd).agents) == 1)
check("remove deletes the member's overrides", vim.fn.isdirectory(cwd .. "/.nvim-agent/workspaces/ephemeral/helper") == 0)
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
