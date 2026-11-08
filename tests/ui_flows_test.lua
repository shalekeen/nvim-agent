-- Interactive-flow test: drives the launcher's pickers and prompts headlessly
-- by scripting ui.select / ui.input answers.
-- Run with: nvim -l tests/ui_flows_test.lua
--
-- Exercises the paths no unit test touches: first-launch agent picker,
-- define-new-agent inline, the resume / new / load startup picker, the
-- switch confirmation (which must come AFTER agent selection), runtime
-- add/remove with pickers and confirmations, copy, rename, save-as, stop,
-- restart, message, and the team status float. A stub adapter whose CLI is
-- `sleep` stands in for the real agent.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if ROOT == "" or ROOT == "tests" then
	ROOT = "."
end
ROOT = vim.fn.fnamemodify(ROOT, ":p"):gsub("/$", "")
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(ROOT)
package.preload["which-key"] = function() return { add = function() end } end
package.preload["barbar"] = function() return {} end
package.preload["barbar.state"] = function() return nil end
package.preload["barbar.ui.render"] = function() return nil end

local sandbox = vim.fn.tempname()
local cwd = sandbox .. "/proj"
vim.fn.mkdir(cwd, "p")
vim.cmd("cd " .. vim.fn.fnameescape(cwd))
require("nvim-agent").setup({ adapter = { get_cmd = function() return { "sh", "-c", "sleep 30" } end }, base_dir = sandbox .. "/base", auto_open = false })

local ui = require("nvim-agent.ui")
local L, S, W, A = require("nvim-agent.launcher"), require("nvim-agent.session"), require("nvim-agent.workspace"), require("nvim-agent.agent")

-- Scripted answers. select: answer by exact label, by prefix "^...", or by index.
local script = {}
local trace = {}
local function answer(kind, prompt, items)
	local a = table.remove(script, 1)
	if a == nil then error(("no scripted %s answer for prompt %q"):format(kind, tostring(prompt))) end
	table.insert(trace, ("%s[%s] -> %s"):format(kind, tostring(prompt), tostring(a)))
	return a
end
ui.select = function(items, opts, cb)
	local a = answer("select", opts and opts.prompt, items)
	if a == false then return cb(nil, nil) end
	if type(a) == "number" then return cb(items[a], a) end
	for i, it in ipairs(items) do
		if it == a or (type(a) == "string" and a:sub(1, 1) == "^" and it:find(a:sub(2), 1, true) == 1) then return cb(it, i) end
	end
	error(("select answer %q not among items: %s"):format(tostring(a), vim.inspect(items)))
end
ui.input = function(opts, cb)
	local a = answer("input", opts and opts.title)
	cb(a == false and nil or a)
end
ui.view_readonly = function(lines) trace[#trace + 1] = "view_readonly(" .. #lines .. " lines)"; return 0, 0 end

local fails, total = 0, 0
local function check(label, ok, detail)
	total = total + 1
	print((ok and "PASS " or "FAIL ") .. label .. (ok and "" or (" — " .. tostring(detail))))
	if not ok then fails = fails + 1 end
end
local function wait_running(name)
	vim.wait(2000, function() local s = S.get_by_name(name); return s and s.jobid ~= nil end)
	return S.get_by_name(name)
end

A.create("engineer", { role = "builds things" })
A.create("qa", { role = "tests things" })

-- 1. First launch in a directory: ephemeral picker. Add engineer, define a
--    new agent inline, then Done.
script = { "Add agent from library", "^engineer", "Define new agent", "tutor", "teaches", "Done — launch" }
L.startup(cwd)
check("first launch created ephemeral manifest", W.exists(W.EPHEMERAL, cwd))
local eph = W.read(W.EPHEMERAL, cwd)
check("ephemeral has engineer + tutor", eph and #eph.agents == 2 and eph.agents[1].agent == "engineer" and eph.agents[2].agent == "tutor", vim.inspect(eph))
check("define-new created the global agent with its role", A.read_role("tutor") == "teaches")
vim.wait(1500, function() return #S.list() == 2 and S.list()[1].jobid and S.list()[2].jobid end)
check("both members launched", wait_running("engineer") and wait_running("tutor"))
check("current workspace is ephemeral", W.get_current() and W.get_current().name == W.EPHEMERAL)
check("script fully consumed", #script == 0, vim.inspect(script))

-- 2. Runtime add via picker, duplicate agent gets a prompted session name.
script = { "^engineer", "engineer-2" }
L.add_agent(nil, nil, cwd)
check("add via picker with duplicate agent prompts for a session name", W.find_entry(W.get_current(), "engineer-2") ~= nil, vim.inspect(W.get_current().agents))
check("duplicate member launched", wait_running("engineer-2") ~= nil)

-- 3. Remove via picker with confirmation.
script = { "engineer-2", "^Yes" }
L.remove_agent(nil, cwd)
check("remove via picker removes member", W.find_entry(W.get_current(), "engineer-2") == nil)
check("remove via picker closes session", S.get_by_name("engineer-2") == nil)
script = { "tutor", "Cancel" }
L.remove_agent(nil, cwd)
check("remove cancelled keeps member", W.find_entry(W.get_current(), "tutor") ~= nil and S.get_by_name("tutor") ~= nil)

-- 4. Promote ephemeral via save-as; then new workspace via picker flow.
script = { "sprint" }
L.save_workspace_as(nil, cwd)
check("save-as renamed the live workspace", W.get_current().name == "sprint" and W.exists("sprint", cwd) and not W.exists(W.EPHEMERAL, cwd))

-- new_workspace: name, add qa, Done → activate asks to switch (live sessions exist) → yes
script = { "review", "Add agent from library", "^qa", "Done — launch", "^Yes" }
L.new_workspace(cwd)
check("new workspace saved with qa", W.read("review", cwd) and W.read("review", cwd).agents[1].agent == "qa", vim.inspect(W.read("review", cwd)))
check("switch stopped the previous workspace's sessions", S.get_by_name("engineer") == nil and S.get_by_name("tutor") == nil)
check("qa launched in the new workspace", wait_running("qa") ~= nil and W.get_current().name == "review")

-- 4b. Cancelling the agent picker for a new workspace must NOT have stopped
--     the live workspace (the switch confirmation comes after the picker).
script = { "abandoned", false }
L.new_workspace(cwd)
check("cancelled new-workspace picker leaves current workspace live", W.get_current().name == "review" and S.get_by_name("qa") ~= nil and S.is_running(S.get_by_name("qa")))
check("abandoned manifest exists but is empty", W.exists("abandoned", cwd) and #W.read("abandoned", cwd).agents == 0)

-- 5. Startup picker on a later launch: Resume/New/Load rows; choose Load sprint, confirm switch.
script = { "^Load 'sprint'", "^Yes" }
L.startup(cwd)
check("startup load switched to sprint", W.get_current().name == "sprint", W.get_current() and W.get_current().name)
check("sprint members relaunched", wait_running("engineer") and wait_running("tutor"))
check("qa stopped on switch", S.get_by_name("qa") == nil)

-- Startup picker again: cancel (escape) does nothing.
script = { false }
L.startup(cwd)
check("startup cancel leaves workspace untouched", W.get_current().name == "sprint" and #S.list() == 2)

-- Startup with no ephemeral present offers "Start ephemeral workspace".
script = { "Start ephemeral workspace", "Add agent from library", "^qa", "Done — launch", "^Yes" }
L.startup(cwd)
check("start ephemeral created a fresh ephemeral", W.exists(W.EPHEMERAL, cwd) and W.get_current().name == W.EPHEMERAL)
check("fresh ephemeral picked qa", wait_running("qa") ~= nil and #S.list() == 1)

-- 6. Library management via pickers: copy, rename workspace, delete agent with references.
script = { "^engineer", "engineer-proj" }
L.copy_agent(nil, nil)
check("copy via picker", A.exists("engineer-proj"))
vim.cmd("tabonly | only") -- copy opened a 2x2 grid tab; tidy
script = { "sprint", "sprint-2" }
L.rename_workspace(nil, nil, cwd)
check("rename via picker", W.exists("sprint-2", cwd) and not W.exists("sprint", cwd))
script = { "^tutor", "^Yes" }
L.delete_agent(nil, cwd)
check("delete via picker removes the agent", not A.exists("tutor"))

-- 7. Message, stop via picker (single running → no picker), team status.
L.message_agent("qa", "hello")
check("message_agent to a running agent does not error", true)
script = {}
L.stop_agent(nil)
vim.wait(3000, function() return S.get_by_name("qa").state == "exited" end)
check("stop via picker (single candidate) stops it", S.get_by_name("qa").state == "exited")
script = { "qa" }
L.message_agent(nil, "hi")
check("message to an exited agent is refused without error", true)
L.team_status(cwd)
check("team status rendered", trace[#trace]:find("view_readonly") ~= nil, trace[#trace])
script = {}
L.restart_agent(nil, cwd)
check("restart via picker (single exited) relaunches", wait_running("qa") ~= nil)

-- 8. Switch session picker, jump, list.
script = { "^qa" }
L.switch_session(nil)
L.jump_session(1)
L.jump_session(9)
L.list_sessions_ui()
L.list_workspaces_ui(cwd)
L.list_agents_ui()
L.show_overrides_ui(cwd)
check("navigation helpers run without error", true)

-- 9. Unknown agent via add: error path.
L.add_agent("nope", nil, cwd)
check("add of unknown agent is refused", W.find_entry(W.get_current(), "nope") == nil)

check("all scripted answers consumed", #script == 0, vim.inspect(script))

for _, s in ipairs(S.list()) do S.close(s.id) end
vim.cmd("cd " .. vim.fn.fnameescape(ROOT))
vim.fn.delete(sandbox, "rf")
print(("\n%d/%d checks passed"):format(total - fails, total))
if fails > 0 then
	print("--- trace ---")
	for _, t in ipairs(trace) do print(t) end
	os.exit(1)
end
