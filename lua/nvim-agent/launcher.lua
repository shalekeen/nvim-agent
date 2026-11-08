-- Interactive flows: startup picker, agent selection, workspace and agent
-- management at runtime, and the non-interactive spawn path used by the
-- spawn_agent MCP tool.
--
-- Everything here is UI glue over three data modules:
--   agent.lua     — the global agent library (~/.nvim-agent/agents/)
--   workspace.lua — manifests (<cwd>/.nvim-agent/workspaces/<name>/) + the
--                   live workspace for this instance
--   session.lua   — running / exited agents in this instance
--
-- Invariants this module maintains:
--   * every manifest change (add / remove / rename) is written immediately
--   * a workspace member always has a session once the workspace is live,
--     even if its CLI has exited; relaunch never recreates the session
--   * a session's active_dir is a mirror of its agent; nothing here ever
--     writes agent files except through agent.load / agent.save

local M = {}

local function ui()
	return require("nvim-agent.ui")
end
local function agent_mod()
	return require("nvim-agent.agent")
end
local function workspace_mod()
	return require("nvim-agent.workspace")
end
local function session_mod()
	return require("nvim-agent.session")
end
local function terminal()
	return require("nvim-agent.terminal")
end

local function notify(msg, level)
	vim.notify("nvim-agent: " .. msg, level or vim.log.levels.INFO)
end

local function focus_nvim_tree()
	vim.defer_fn(function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].filetype == "NvimTree" then
				vim.api.nvim_set_current_win(win)
				vim.cmd("stopinsert")
				return
			end
		end
	end, 200)
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local c = f:read("*a")
	f:close()
	return c
end

local function trunc(s, n)
	s = (s or ""):gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", "")
	if #s > n then
		return s:sub(1, n - 1) .. "…"
	end
	return s
end

------------------------------------------------------------------------
-- Status files
------------------------------------------------------------------------

--- Write the initial status file for a session so peers discover it at
--- once. Lock + tmpfile-rename: the agent's own MCP update_status may fire
--- seconds after launch on the same path.
local function write_initial_status(sess, cwd, task)
	local status_dir = workspace_mod().instance_runtime_dir(cwd) .. "/status"
	vim.fn.mkdir(status_dir, "p")
	local status_path = status_dir .. "/" .. sess.name .. ".json"
	local role = read_file(sess.active_dir .. "/role.md")
	if role and role:match("^%s*$") then
		role = nil
	end
	local payload = vim.json.encode({
		agent = sess.name,
		role = role and (role:gsub("%s+$", "")) or nil,
		current_task = task,
		updated_at = os.date("%Y-%m-%dT%H:%M:%SZ"),
	})
	local filelock = require("nvim-agent.mcp.filelock")
	local got, lock_err = filelock.acquire(status_path, { agent = "nvim-launch", retries = 5, delay_ms = 100 })
	if not got then
		notify("could not lock initial status for '" .. sess.name .. "': " .. tostring(lock_err), vim.log.levels.WARN)
		return
	end
	local tmp = status_path .. ".tmp"
	local sf = io.open(tmp, "w")
	if sf then
		sf:write(payload)
		sf:close()
		local renamed, rerr = os.rename(tmp, status_path)
		if not renamed then
			os.remove(tmp)
			notify("failed to write initial status for '" .. sess.name .. "': " .. tostring(rerr), vim.log.levels.WARN)
		end
	end
	filelock.release(status_path)
end

------------------------------------------------------------------------
-- Sessions for manifest entries
------------------------------------------------------------------------

--- Create the session for a manifest entry: mirror the global agent into
--- active_dir, then lay this workspace's override files on top. Does not
--- open a terminal.
--- @return table|nil sess
local function create_session_for_entry(manifest, entry, cwd)
	local sess, err = session_mod().create(entry.name, entry.agent)
	if not sess then
		notify("failed to create session '" .. entry.name .. "': " .. (err or "?"), vim.log.levels.ERROR)
		return nil
	end
	local ok, lerr = agent_mod().load(entry.agent, sess.active_dir)
	if not ok then
		notify("'" .. entry.name .. "': " .. (lerr or "agent load failed") .. " — launching with defaults", vim.log.levels.WARN)
	end
	local applied = workspace_mod().apply_overrides(manifest.name, entry.name, sess.active_dir, cwd)
	if #applied > 0 then
		sess.overrides = applied
	end
	write_initial_status(sess, cwd, "launching")
	return sess
end

--- Reload a session's active_dir from its agent + this workspace's
--- overrides. Used after overrides are cleared. Returns the files applied.
local function reload_session_files(manifest, sess, cwd)
	agent_mod().load(sess.agent, sess.active_dir)
	return workspace_mod().apply_overrides(manifest.name, sess.name, sess.active_dir, cwd)
end

local function close_all_sessions()
	local sm = session_mod()
	for _, sess in ipairs(sm.list()) do
		sm.close(sess.id)
	end
end

------------------------------------------------------------------------
-- Launch
------------------------------------------------------------------------

--- Launch every member of `manifest` that is not already live and make it
--- the current workspace. Members whose sessions already exist are left
--- untouched, so calling this on the live workspace is a no-op for them.
--- @param manifest table
--- @param cwd string|nil
function M.launch(manifest, cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	local sm = session_mod()

	local adapter = require("nvim-agent.adapter").get_active()
	if adapter and adapter.setup_project_permissions then
		adapter:setup_project_permissions(cwd)
	end

	ws.init_runtime(cwd)
	ws.set_current(manifest)

	local created = {}
	for _, entry in ipairs(manifest.agents or {}) do
		if not sm.get_by_name(entry.name) then
			local sess = create_session_for_entry(manifest, entry, cwd)
			if sess then
				table.insert(created, sess)
			end
		end
	end

	if #created == 0 then
		if #(manifest.agents or {}) == 0 then
			notify("workspace '" .. manifest.name .. "' is live but has no agents yet — add one with :NvimAgent agent add")
		end
		return
	end

	focus_nvim_tree()
	local ids = {}
	for _, sess in ipairs(created) do
		table.insert(ids, sess.id)
	end
	vim.defer_fn(function()
		if #ids > 1 then
			terminal().open_grid(ids, 4)
		else
			terminal().open(ids[1])
		end
	end, 300)

	notify(string.format("workspace '%s' launched (%d agent%s)", manifest.name, #created, #created == 1 and "" or "s"))
end

--- Make `manifest` the live workspace. If another workspace is live with
--- running sessions, confirm before stopping them. An empty manifest goes
--- through the agent picker first.
--- @param manifest table
--- @param cwd string|nil
function M.activate(manifest, cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	local sm = session_mod()
	local current = ws.get_current()

	local function go()
		if #(manifest.agents or {}) == 0 then
			M.pick_agents(manifest, cwd, function(result)
				if result then
					M.launch(result, cwd)
				end
			end)
		else
			M.launch(manifest, cwd)
		end
	end

	local live = sm.list()
	if current and current.name ~= manifest.name and #live > 0 then
		ui().select({ "Yes — stop them and switch", "Cancel" }, {
			prompt = string.format("Switch from '%s' to '%s'? (%d live agent%s will be stopped)", current.name, manifest.name, #live, #live == 1 and "" or "s"),
			width = 80,
		}, function(choice)
			if choice and choice:match("^Yes") then
				close_all_sessions()
				go()
			end
		end)
		return
	end

	go()
end

------------------------------------------------------------------------
-- Agent library pickers
------------------------------------------------------------------------

--- Pick an agent from the global library. User agents first, then a
--- "Spawned" section. Calls on_pick(name) or on_pick(nil) on cancel.
--- @param opts table|nil  { prompt = string, extra = { label → fn } }
--- @param on_pick fun(name: string|nil)
function M.pick_library_agent(opts, on_pick)
	opts = opts or {}
	local agents = agent_mod().list()
	local options, map = {}, {}
	for _, a in ipairs(agents) do
		local label = (a.spawned and "[spawned] " or "") .. a.name .. "  — " .. trunc(a.role or "(no role)", 50)
		table.insert(options, label)
		map[label] = { agent = a.name }
	end
	for label, fn in pairs(opts.extra or {}) do
		table.insert(options, label)
		map[label] = { fn = fn }
	end
	if #options == 0 then
		notify("no agents defined yet", vim.log.levels.INFO)
		on_pick(nil)
		return
	end
	ui().select(options, { prompt = opts.prompt or "Pick an agent", width = 90 }, function(choice)
		local sel = choice and map[choice]
		if not sel then
			on_pick(nil)
		elseif sel.fn then
			sel.fn(on_pick)
		else
			on_pick(sel.agent)
		end
	end)
end

--- Define a new global agent interactively: name → role → create from
--- defaults → open its prompt for editing. Calls on_done(name|nil).
--- @param on_done fun(name: string|nil)|nil
function M.define_agent(on_done)
	on_done = on_done or function() end
	local am = agent_mod()
	ui().input({ prompt = "", title = "New agent — name" }, function(name)
		if not name or name == "" then
			return on_done(nil)
		end
		local ok, err = am.validate_name(name)
		if not ok then
			notify(err, vim.log.levels.ERROR)
			return on_done(nil)
		end
		if am.exists(name) then
			notify("agent '" .. name .. "' already exists", vim.log.levels.ERROR)
			return on_done(nil)
		end
		ui().input({
			prompt = "",
			title = "Role for '" .. name .. "' (guides the agent; peers use it to delegate)",
			width = 90,
		}, function(role)
			if not role or role:match("^%s*$") then
				notify("a role is required to define an agent", vim.log.levels.ERROR)
				return on_done(nil)
			end
			local cok, cerr = am.create(name, { role = role })
			if not cok then
				notify(cerr, vim.log.levels.ERROR)
				return on_done(nil)
			end
			notify("agent '" .. name .. "' created — edit its prompt in the split (saved files take effect on next launch)")
			vim.cmd("split " .. vim.fn.fnameescape(am.dir(name, false) .. "/system_prompt.md"))
			on_done(name)
		end)
	end)
end

--- Session name for an agent being added to `manifest`: the agent name when
--- free, otherwise prompt (default "<agent>-2", "-3", ...).
local function resolve_session_name(manifest, agent_name, on_done)
	local ws = workspace_mod()
	if not ws.find_entry(manifest, agent_name) then
		return on_done(agent_name)
	end
	local n = 2
	while ws.find_entry(manifest, agent_name .. "-" .. n) do
		n = n + 1
	end
	ui().input({
		prompt = "",
		title = "'" .. agent_name .. "' is already in the workspace — session name for this copy",
		default = agent_name .. "-" .. n,
		width = 80,
	}, function(name)
		if not name or name == "" then
			return on_done(nil)
		end
		on_done(name)
	end)
end

------------------------------------------------------------------------
-- Agent selection loop (used by first launch, new workspace, empty load)
------------------------------------------------------------------------

--- Loop menu to choose which agents make up `manifest`. Every add/remove is
--- persisted immediately. Calls on_done(manifest) on "Done", on_done(nil)
--- on cancel.
--- @param manifest table
--- @param cwd string|nil
--- @param on_done fun(manifest: table|nil)
function M.pick_agents(manifest, cwd, on_done)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	local ADD, DEFINE, DONE = "Add agent from library", "Define new agent", "Done — launch"

	local function menu()
		local options = {}
		for _, e in ipairs(manifest.agents or {}) do
			local label = "  ✓ " .. e.name
			if e.agent ~= e.name then
				label = label .. "  (" .. e.agent .. ")"
			end
			table.insert(options, label)
		end
		table.insert(options, ADD)
		table.insert(options, DEFINE)
		table.insert(options, DONE)

		ui().select(options, {
			prompt = string.format("Workspace '%s' — agents", manifest.name),
			width = 80,
		}, function(choice, idx)
			if not choice then
				return on_done(nil)
			end
			if choice == DONE then
				return on_done(manifest)
			end
			if choice == ADD then
				M.pick_library_agent({ prompt = "Add agent to '" .. manifest.name .. "'" }, function(agent_name)
					if not agent_name then
						return menu()
					end
					resolve_session_name(manifest, agent_name, function(sname)
						if sname then
							local ok, err = ws.add_entry(manifest, { agent = agent_name, name = sname }, cwd)
							if not ok then
								notify(err, vim.log.levels.ERROR)
							end
						end
						menu()
					end)
				end)
				return
			end
			if choice == DEFINE then
				M.define_agent(function(name)
					if name then
						local ok, err = ws.add_entry(manifest, { agent = name, name = name }, cwd)
						if not ok then
							notify(err, vim.log.levels.ERROR)
						end
					end
					menu()
				end)
				return
			end
			-- Existing member clicked
			local entry = manifest.agents[idx]
			if entry then
				ui().select({ "Remove from workspace", "Keep" }, {
					prompt = "Agent '" .. entry.name .. "'",
					width = 50,
				}, function(action)
					if action == "Remove from workspace" then
						ws.remove_entry(manifest, entry.name, cwd)
					end
					menu()
				end)
				return
			end
			menu()
		end)
	end

	menu()
end

------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------

--- Entry point for :NvimAgent with no live workspace, and for auto_open.
--- First launch in a directory goes straight into agent selection for the
--- ephemeral workspace; later launches get the resume / new / load picker.
--- @param cwd string|nil
function M.startup(cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()

	if not ws.any_exist(cwd) then
		local m = ws.new_manifest(ws.EPHEMERAL)
		ws.save(m, cwd)
		notify("first launch in this directory — pick the agents for your ephemeral workspace")
		M.pick_agents(m, cwd, function(result)
			if result then
				M.launch(result, cwd)
			end
		end)
		return
	end

	local options, map = {}, {}
	local function agents_label(m)
		local names = {}
		for _, e in ipairs(m.agents or {}) do
			table.insert(names, e.name)
		end
		return #names > 0 and ("  [" .. table.concat(names, ", ") .. "]") or "  [empty]"
	end

	for _, m in ipairs(ws.list(cwd)) do
		if m.ephemeral then
			local label = "Resume ephemeral workspace" .. agents_label(m)
			table.insert(options, label)
			map[label] = m
		end
	end
	local NEW = "New workspace"
	table.insert(options, NEW)
	for _, m in ipairs(ws.list(cwd)) do
		if not m.ephemeral then
			local label = "Load '" .. m.name .. "'" .. agents_label(m)
			table.insert(options, label)
			map[label] = m
		end
	end
	if not ws.exists(ws.EPHEMERAL, cwd) then
		local label = "Start ephemeral workspace"
		table.insert(options, 1, label)
		map[label] = "ephemeral"
	end

	ui().select(options, { prompt = "nvim-agent", width = 80 }, function(choice)
		if not choice then
			return
		end
		if choice == NEW then
			return M.new_workspace(cwd)
		end
		local sel = map[choice]
		if sel == "ephemeral" then
			local m = ws.new_manifest(ws.EPHEMERAL)
			ws.save(m, cwd)
			return M.activate(m, cwd)
		end
		if sel then
			M.activate(sel, cwd)
		end
	end)
end

------------------------------------------------------------------------
-- Workspace management
------------------------------------------------------------------------

--- Create a named workspace, pick its agents, launch it.
--- @param cwd string|nil
function M.new_workspace(cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	ui().input({ prompt = "", title = "New workspace — name" }, function(name)
		if not name or name == "" then
			return
		end
		local ok, err = ws.validate_name(name)
		if not ok then
			return notify(err, vim.log.levels.ERROR)
		end
		if ws.exists(name, cwd) then
			return notify("workspace '" .. name .. "' already exists", vim.log.levels.ERROR)
		end
		local m = ws.new_manifest(name)
		ws.save(m, cwd)
		M.activate(m, cwd)
	end)
end

--- Load a workspace by name, or via picker.
--- @param name string|nil
--- @param cwd string|nil
function M.load_workspace(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	if name and name ~= "" then
		local m = ws.read(name, cwd)
		if not m then
			return notify("workspace '" .. name .. "' not found", vim.log.levels.ERROR)
		end
		return M.activate(m, cwd)
	end
	local all = ws.list(cwd)
	if #all == 0 then
		notify("no workspaces in this directory yet — creating one")
		return M.new_workspace(cwd)
	end
	local options, map = {}, {}
	for _, m in ipairs(all) do
		local names = {}
		for _, e in ipairs(m.agents or {}) do
			table.insert(names, e.name)
		end
		local label = m.name .. "  [" .. table.concat(names, ", ") .. "]"
		table.insert(options, label)
		map[label] = m
	end
	ui().select(options, { prompt = "Load workspace", width = 80 }, function(choice)
		if choice and map[choice] then
			M.activate(map[choice], cwd)
		end
	end)
end

--- @param cwd string|nil
function M.list_workspaces_ui(cwd)
	local all = workspace_mod().list(cwd)
	if #all == 0 then
		return notify("no workspaces in this directory")
	end
	local current = workspace_mod().get_current()
	local lines = {}
	for _, m in ipairs(all) do
		local names = {}
		for _, e in ipairs(m.agents or {}) do
			table.insert(names, e.name)
		end
		local marker = (current and current.name == m.name) and " *" or ""
		table.insert(lines, string.format("  %s%s  [%s]", m.name, marker, table.concat(names, ", ")))
	end
	notify("workspaces:\n" .. table.concat(lines, "\n"))
end

local function pick_workspace(prompt, cwd, on_pick)
	local all = workspace_mod().list(cwd)
	if #all == 0 then
		notify("no workspaces in this directory")
		return on_pick(nil)
	end
	local names = {}
	for _, m in ipairs(all) do
		table.insert(names, m.name)
	end
	ui().select(names, { prompt = prompt, width = 70 }, function(choice)
		on_pick(choice)
	end)
end

--- Delete a workspace manifest. Removing the live workspace also stops its
--- agents.
--- @param name string|nil
--- @param cwd string|nil
function M.remove_workspace(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	local function do_remove(n)
		local current = ws.get_current()
		if current and current.name == n then
			close_all_sessions()
		end
		local ok, err = ws.delete(n, cwd)
		if ok then
			notify("workspace '" .. n .. "' removed")
		else
			notify(err, vim.log.levels.ERROR)
		end
	end
	if name and name ~= "" then
		return do_remove(name)
	end
	pick_workspace("Remove workspace", cwd, function(n)
		if n then
			do_remove(n)
		end
	end)
end

--- Rename a workspace. With no args, picks the source and prompts for the
--- new name.
--- @param old string|nil
--- @param new string|nil
--- @param cwd string|nil
function M.rename_workspace(old, new, cwd)
	cwd = cwd or vim.fn.getcwd()
	local ws = workspace_mod()
	local function do_rename(o, n)
		local ok, err = ws.rename(o, n, cwd)
		if ok then
			notify("workspace '" .. o .. "' renamed to '" .. n .. "'")
		else
			notify(err, vim.log.levels.ERROR)
		end
	end
	local function ask_new(o)
		ui().input({ prompt = "", title = "New name for workspace '" .. o .. "'" }, function(n)
			if n and n ~= "" then
				do_rename(o, n)
			end
		end)
	end
	if old and old ~= "" and new and new ~= "" then
		return do_rename(old, new)
	end
	if old and old ~= "" then
		return ask_new(old)
	end
	pick_workspace("Rename workspace", cwd, function(o)
		if o then
			ask_new(o)
		end
	end)
end

--- Promote the live workspace (typically the ephemeral one) to a named
--- workspace.
--- @param name string|nil
--- @param cwd string|nil
function M.save_workspace_as(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local current = workspace_mod().get_current()
	if not current then
		return notify("no live workspace", vim.log.levels.WARN)
	end
	if name and name ~= "" then
		return M.rename_workspace(current.name, name, cwd)
	end
	ui().input({ prompt = "", title = "Save workspace '" .. current.name .. "' as" }, function(n)
		if n and n ~= "" then
			M.rename_workspace(current.name, n, cwd)
		end
	end)
end

------------------------------------------------------------------------
-- Membership at runtime
------------------------------------------------------------------------

local function require_live_workspace()
	local m = workspace_mod().get_current()
	if not m then
		notify("no live workspace — run :NvimAgent first", vim.log.levels.WARN)
	end
	return m
end

--- Add an agent to the live workspace and launch it.
--- @param agent_name string|nil   library agent; nil → picker (with "Define new agent")
--- @param session_name string|nil default: agent name (prompted on collision)
--- @param cwd string|nil
function M.add_agent(agent_name, session_name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = require_live_workspace()
	if not m then
		return
	end
	local ws = workspace_mod()

	local function finish(aname, sname)
		local ok, err = ws.add_entry(m, { agent = aname, name = sname }, cwd)
		if not ok then
			return notify(err, vim.log.levels.ERROR)
		end
		local entry = ws.find_entry(m, sname)
		local sess = create_session_for_entry(m, entry, cwd)
		if sess then
			vim.defer_fn(function()
				terminal().open(sess.id)
			end, 100)
			notify("agent '" .. sname .. "' added to workspace '" .. m.name .. "'")
		end
	end

	local function with_agent(aname)
		if not aname then
			return
		end
		if session_name and session_name ~= "" then
			return finish(aname, session_name)
		end
		resolve_session_name(m, aname, function(sname)
			if sname then
				finish(aname, sname)
			end
		end)
	end

	if agent_name and agent_name ~= "" then
		if not agent_mod().exists(agent_name) then
			return notify("agent '" .. agent_name .. "' not found in the global library", vim.log.levels.ERROR)
		end
		return with_agent(agent_name)
	end

	M.pick_library_agent({
		prompt = "Add agent to '" .. m.name .. "'",
		extra = {
			["Define new agent"] = function(on_pick)
				M.define_agent(on_pick)
			end,
		},
	}, with_agent)
end

--- Remove a member from the live workspace: stops its process, drops its
--- status file and the manifest entry.
--- @param name string|nil  session name; nil → picker
--- @param cwd string|nil
function M.remove_agent(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = require_live_workspace()
	if not m then
		return
	end
	local ws = workspace_mod()
	local sm = session_mod()

	local function do_remove(n)
		local sess = sm.get_by_name(n)
		if sess then
			sm.close(sess.id)
		end
		local ok, err = ws.remove_entry(m, n, cwd)
		if ok then
			notify("agent '" .. n .. "' removed from workspace '" .. m.name .. "'")
		else
			notify(err, vim.log.levels.ERROR)
		end
	end

	if name and name ~= "" then
		return do_remove(name)
	end
	local names = {}
	for _, e in ipairs(m.agents or {}) do
		table.insert(names, e.name)
	end
	if #names == 0 then
		return notify("workspace has no agents")
	end
	ui().select(names, { prompt = "Remove agent from '" .. m.name .. "'", width = 70 }, function(choice)
		if not choice then
			return
		end
		ui().select({ "Yes — stop and remove", "Cancel" }, {
			prompt = "Remove '" .. choice .. "'?",
			width = 50,
		}, function(confirm)
			if confirm and confirm:match("^Yes") then
				do_remove(choice)
			end
		end)
	end)
end

--- Relaunch an exited member (or one whose session was never created).
--- @param name string|nil  session name; nil → picker over non-running members
--- @param cwd string|nil
function M.restart_agent(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = require_live_workspace()
	if not m then
		return
	end
	local ws = workspace_mod()
	local sm = session_mod()

	local function do_restart(n)
		local entry = ws.find_entry(m, n)
		if not entry then
			return notify("'" .. n .. "' is not in workspace '" .. m.name .. "'", vim.log.levels.ERROR)
		end
		local sess = sm.get_by_name(n)
		if sess and sm.is_running(sess) then
			return notify("agent '" .. n .. "' is already running")
		end
		if not sess then
			sess = create_session_for_entry(m, entry, cwd)
			if not sess then
				return
			end
		else
			write_initial_status(sess, cwd, "relaunching")
		end
		terminal().open(sess.id)
		notify("agent '" .. n .. "' relaunched")
	end

	if name and name ~= "" then
		return do_restart(name)
	end
	local candidates = {}
	for _, e in ipairs(m.agents or {}) do
		local sess = sm.get_by_name(e.name)
		if not sess or not sm.is_running(sess) then
			table.insert(candidates, e.name)
		end
	end
	if #candidates == 0 then
		return notify("every agent in '" .. m.name .. "' is running")
	end
	if #candidates == 1 then
		return do_restart(candidates[1])
	end
	ui().select(candidates, { prompt = "Relaunch agent", width = 70 }, function(choice)
		if choice then
			do_restart(choice)
		end
	end)
end

------------------------------------------------------------------------
-- Global library management
------------------------------------------------------------------------

--- Open an agent's definition files in a 2×2 grid in a new tab.
local function open_agent_files(dir)
	vim.cmd("tabnew")
	vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/system_prompt.md"))
	vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/role.md"))
	vim.cmd("wincmd h")
	vim.cmd("split " .. vim.fn.fnameescape(dir .. "/user_notes.md"))
	vim.cmd("wincmd l")
	vim.cmd("split " .. vim.fn.fnameescape(dir .. "/persistent_dirs.json"))
	vim.cmd("wincmd =")
	vim.cmd("wincmd h")
	vim.cmd("wincmd k")
end

--- Edit a library agent's files. Live sessions built from it keep their
--- mirror until relaunched.
--- @param name string|nil
function M.edit_agent(name)
	local am = agent_mod()
	local function go(n)
		local dir = am.resolve(n)
		if not dir then
			return notify("agent '" .. n .. "' not found", vim.log.levels.ERROR)
		end
		open_agent_files(dir)
		notify("editing agent '" .. n .. "' (live sessions pick up changes on relaunch)")
	end
	if name and name ~= "" then
		return go(name)
	end
	M.pick_library_agent({ prompt = "Edit agent" }, function(n)
		if n then
			go(n)
		end
	end)
end

--- Copy a library agent under a new name (how you make a project-specific
--- variant, or adopt a spawned agent).
--- @param src string|nil
--- @param dst string|nil
function M.copy_agent(src, dst)
	local am = agent_mod()
	local function do_copy(s, d)
		local ok, err = am.copy(s, d)
		if ok then
			notify("agent '" .. s .. "' copied to '" .. d .. "'")
			open_agent_files(am.dir(d, false))
		else
			notify(err, vim.log.levels.ERROR)
		end
	end
	local function ask_dst(s)
		ui().input({ prompt = "", title = "Copy agent '" .. s .. "' as" }, function(d)
			if d and d ~= "" then
				do_copy(s, d)
			end
		end)
	end
	if src and src ~= "" and dst and dst ~= "" then
		return do_copy(src, dst)
	end
	if src and src ~= "" then
		return ask_dst(src)
	end
	M.pick_library_agent({ prompt = "Copy agent" }, function(s)
		if s then
			ask_dst(s)
		end
	end)
end

--- Delete a library agent. Warns about workspaces in this project that
--- reference it; live sessions keep running on their mirror.
--- @param name string|nil
--- @param cwd string|nil
function M.delete_agent(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local am = agent_mod()
	local ws = workspace_mod()
	local function do_delete(n)
		local users = {}
		for _, m in ipairs(ws.list(cwd)) do
			for _, e in ipairs(m.agents or {}) do
				if e.agent == n then
					table.insert(users, m.name .. "/" .. e.name)
					break
				end
			end
		end
		local prompt = "Delete agent '" .. n .. "'?"
		if #users > 0 then
			prompt = prompt .. "  (referenced by: " .. table.concat(users, ", ") .. ")"
		end
		ui().select({ "Yes — delete", "Cancel" }, { prompt = prompt, width = 90 }, function(choice)
			if not (choice and choice:match("^Yes")) then
				return
			end
			local ok, err = am.delete(n)
			if ok then
				notify("agent '" .. n .. "' deleted")
			else
				notify(err, vim.log.levels.ERROR)
			end
		end)
	end
	if name and name ~= "" then
		return do_delete(name)
	end
	M.pick_library_agent({ prompt = "Delete agent" }, function(n)
		if n then
			do_delete(n)
		end
	end)
end

function M.list_agents_ui()
	local agents = agent_mod().list()
	if #agents == 0 then
		return notify("no agents defined — :NvimAgent agent define")
	end
	local lines, in_spawned = {}, false
	for _, a in ipairs(agents) do
		if a.spawned and not in_spawned then
			in_spawned = true
			table.insert(lines, "  -- spawned --")
		end
		table.insert(lines, string.format("  %s  — %s", a.name, trunc(a.role or "(no role)", 60)))
	end
	notify("agents:\n" .. table.concat(lines, "\n"))
end

------------------------------------------------------------------------
-- Overrides: edits from a live session go to this workspace, not global
------------------------------------------------------------------------

--- Write one file of a session's active_dir to this workspace's override
--- for that member. Called whenever a context file is edited from a live
--- session (BufWritePost on active/*, the notes/dirs/prompt commands and
--- keymaps). The first write creates the override with the session's
--- current content, which is exactly "initialise from the global, then
--- edit".
--- @param sess table
--- @param file string   one of agent.AGENT_FILES
--- @param silent boolean|nil
--- @return boolean
function M.sync_session_file(sess, file, silent)
	local m = workspace_mod().get_current()
	if not sess or not m then
		return false
	end
	local ok, err = workspace_mod().copy_override_from(m.name, sess.name, file, sess.active_dir .. "/" .. file, vim.fn.getcwd())
	if not ok then
		notify("could not save override for '" .. sess.name .. "': " .. tostring(err), vim.log.levels.WARN)
		return false
	end
	sess.overrides = workspace_mod().list_overrides(m.name, sess.name, vim.fn.getcwd())
	if not silent then
		notify(string.format("%s saved as a '%s' override for '%s' (global agent '%s' untouched)", file, m.name, sess.name, sess.agent))
	end
	return true
end

--- Push a session's current files to its GLOBAL agent definition, then
--- drop this workspace's overrides for it (they would be identical).
--- @param name string|nil  session name; nil → picker
function M.push_agent(name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = require_live_workspace()
	if not m then
		return
	end
	local function do_push(sess)
		local ok, err = agent_mod().save(sess.agent, sess.active_dir)
		if not ok then
			return notify(err, vim.log.levels.ERROR)
		end
		workspace_mod().clear_overrides(m.name, sess.name, nil, cwd)
		sess.overrides = nil
		notify(string.format("'%s' pushed to global agent '%s'; workspace overrides cleared", sess.name, sess.agent))
	end
	if name and name ~= "" then
		local sess = session_mod().get_by_name(name)
		if not sess then
			return notify("no session '" .. name .. "'", vim.log.levels.ERROR)
		end
		return do_push(sess)
	end
	M.pick_session("Push session context to its global agent", function(sess)
		if sess then
			do_push(sess)
		end
	end)
end

--- Drop one or all overrides for a member and reload the affected files
--- from the global agent into the live session.
--- @param name string|nil  session name; nil → picker
--- @param file string|nil  one file, or nil for all
function M.reset_overrides(name, file, cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = require_live_workspace()
	if not m then
		return
	end
	local ws = workspace_mod()
	local function do_reset(sess)
		local had = ws.list_overrides(m.name, sess.name, cwd)
		if #had == 0 then
			return notify("'" .. sess.name .. "' has no overrides in '" .. m.name .. "'")
		end
		ws.clear_overrides(m.name, sess.name, file, cwd)
		reload_session_files(m, sess, cwd)
		sess.overrides = ws.list_overrides(m.name, sess.name, cwd)
		if #sess.overrides == 0 then
			sess.overrides = nil
		end
		notify(string.format("'%s': %s reset to global agent '%s'", sess.name, file or "all overrides", sess.agent))
	end
	if name and name ~= "" then
		local sess = session_mod().get_by_name(name)
		if not sess then
			return notify("no session '" .. name .. "'", vim.log.levels.ERROR)
		end
		return do_reset(sess)
	end
	M.pick_session("Reset overrides for session", function(sess)
		if sess then
			do_reset(sess)
		end
	end)
end

--- Show which files each member overrides in the live workspace.
function M.show_overrides_ui(cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = require_live_workspace()
	if not m then
		return
	end
	local lines = {}
	for _, e in ipairs(m.agents or {}) do
		local files = workspace_mod().list_overrides(m.name, e.name, cwd)
		table.insert(lines, string.format("  %-16s %s", e.name, #files > 0 and table.concat(files, ", ") or "(none — using global '" .. e.agent .. "')"))
	end
	if #lines == 0 then
		return notify("workspace has no agents")
	end
	notify("overrides in '" .. m.name .. "':\n" .. table.concat(lines, "\n"))
end

------------------------------------------------------------------------
-- Liveness helpers
------------------------------------------------------------------------

--- Stop a member's CLI without removing it from the workspace. It becomes
--- "exited" and can be relaunched with restart / spawn_agent.
--- @param name string|nil
function M.stop_agent(name)
	local sm = session_mod()
	local function do_stop(sess)
		if not sm.is_running(sess) then
			return notify("agent '" .. sess.name .. "' is not running")
		end
		terminal().stop(sess.id)
		notify("agent '" .. sess.name .. "' stopped (still in the workspace; restart with :NvimAgent agent restart " .. sess.name .. ")")
	end
	if name and name ~= "" then
		local sess = sm.get_by_name(name)
		if not sess then
			return notify("no session '" .. name .. "'", vim.log.levels.ERROR)
		end
		return do_stop(sess)
	end
	local running = {}
	for _, sess in ipairs(sm.list()) do
		if sm.is_running(sess) then
			table.insert(running, sess)
		end
	end
	if #running == 0 then
		return notify("no running agents")
	end
	if #running == 1 then
		return do_stop(running[1])
	end
	local options, map = {}, {}
	for _, sess in ipairs(running) do
		table.insert(options, sess.name)
		map[sess.name] = sess
	end
	ui().select(options, { prompt = "Stop agent", width = 60 }, function(choice)
		if choice then
			do_stop(map[choice])
		end
	end)
end

--- Type a line into a member's terminal and submit it.
--- @param name string|nil  session name; nil → picker
--- @param text string|nil  nil → prompt
function M.message_agent(name, text)
	local sm = session_mod()
	local function do_send(sess)
		local function send(t)
			if not t or t == "" then
				return
			end
			if not sm.is_running(sess) then
				return notify("agent '" .. sess.name .. "' is not running", vim.log.levels.WARN)
			end
			terminal().send(sess.id, t)
			notify("sent to '" .. sess.name .. "'")
		end
		if text and text ~= "" then
			return send(text)
		end
		ui().input({ prompt = "", title = "Message to '" .. sess.name .. "'", width = 90 }, send)
	end
	if name and name ~= "" then
		local sess = sm.get_by_name(name)
		if not sess then
			return notify("no session '" .. name .. "'", vim.log.levels.ERROR)
		end
		return do_send(sess)
	end
	M.pick_session("Message which agent?", function(sess)
		if sess then
			do_send(sess)
		end
	end)
end

--- Jump to the nth session (creation order). Relaunches it if exited.
--- @param n integer
function M.jump_session(n)
	local sessions = session_mod().list()
	local sess = sessions[n]
	if not sess then
		return notify("no session #" .. tostring(n))
	end
	terminal().open(sess.id)
end

--- Floating overview of the live workspace: every member's state, role,
--- current task from its status file, pending mailbox size, and overrides.
function M.team_status(cwd)
	cwd = cwd or vim.fn.getcwd()
	local m = workspace_mod().get_current()
	if not m then
		return notify("no live workspace", vim.log.levels.WARN)
	end
	local sm = session_mod()
	local inst = workspace_mod().instance_runtime_dir(cwd)
	local lines = { string.format("Workspace: %s    (instance %s)", m.name, sm.instance_id:sub(1, 8)), "" }
	for _, e in ipairs(m.agents or {}) do
		local sess = sm.get_by_name(e.name)
		local state = "not launched"
		if sess and sm.is_running(sess) then
			state = "running"
		elseif sess then
			state = "exited"
		end
		local task, updated = nil, nil
		local raw = read_file(inst .. "/status/" .. e.name .. ".json")
		if raw then
			local ok, data = pcall(vim.json.decode, raw)
			if ok and type(data) == "table" then
				task, updated = data.current_task, data.updated_at
			end
		end
		local mail = vim.fn.getfsize(inst .. "/messages/" .. e.name .. ".md")
		local overrides = workspace_mod().list_overrides(m.name, e.name, cwd)
		local marker = (sess and sess.id == sm.current_id) and "*" or " "
		table.insert(lines, string.format("%s %-16s %-12s agent: %s", marker, e.name, state, e.agent))
		table.insert(lines, "    role:  " .. trunc(agent_mod().read_role(e.agent) or (sess and read_file(sess.active_dir .. "/role.md")) or "(none)", 100))
		if task then
			table.insert(lines, "    task:  " .. trunc(task, 100) .. (updated and ("   (" .. updated .. ")") or ""))
		end
		if mail and mail > 0 then
			table.insert(lines, string.format("    mail:  %d bytes pending", mail))
		end
		if #overrides > 0 then
			table.insert(lines, "    overrides: " .. table.concat(overrides, ", "))
		end
		table.insert(lines, "")
	end
	if #(m.agents or {}) == 0 then
		table.insert(lines, "  (no agents — :NvimAgent agent add)")
	end
	ui().view_readonly(lines, { title = "nvim-agent team", width = math.min(110, vim.o.columns - 4), height = math.min(#lines + 3, vim.o.lines - 4) })
end

------------------------------------------------------------------------
-- Sessions
------------------------------------------------------------------------

local function session_label(sess)
	local sm = session_mod()
	local state = sm.is_running(sess) and "" or "  (exited)"
	local marker = (sess.id == sm.current_id) and " *" or ""
	local agent_part = (sess.agent ~= sess.name) and (" (" .. sess.agent .. ")") or ""
	return string.format("%s%s%s%s", sess.name, agent_part, state, marker)
end

--- Show a picker when there are 2+ sessions; pass the single one through;
--- callback(nil) when there are none.
--- @param prompt string
--- @param callback fun(sess: table|nil)
function M.pick_session(prompt, callback)
	local sm = session_mod()
	local sessions = sm.list()
	if #sessions == 0 then
		return callback(nil)
	end
	if #sessions == 1 then
		return callback(sessions[1])
	end
	local options, map = {}, {}
	for _, sess in ipairs(sessions) do
		local label = session_label(sess)
		table.insert(options, label)
		map[label] = sess
	end
	ui().select(options, { prompt = prompt, width = 70 }, function(choice)
		if choice then
			callback(map[choice])
		end
	end)
end

--- Switch to a session's terminal (relaunching it if it has exited).
--- @param name string|nil
function M.switch_session(name)
	local sm = session_mod()
	if name and name ~= "" then
		local sess = sm.get_by_name(name)
		if not sess then
			return notify("no session '" .. name .. "'", vim.log.levels.ERROR)
		end
		return terminal().open(sess.id)
	end
	local sessions = sm.list()
	if #sessions == 0 then
		return notify("no sessions")
	end
	local options, map = {}, {}
	for _, sess in ipairs(sessions) do
		local label = session_label(sess)
		table.insert(options, label)
		map[label] = sess
	end
	ui().select(options, { prompt = "Switch to session", width = 70 }, function(choice)
		if choice and map[choice] then
			terminal().open(map[choice].id)
		end
	end)
end

function M.list_sessions_ui()
	local sessions = session_mod().list()
	if #sessions == 0 then
		return notify("no sessions")
	end
	local lines = {}
	for _, sess in ipairs(sessions) do
		table.insert(lines, "  " .. session_label(sess))
	end
	notify("sessions:\n" .. table.concat(lines, "\n"))
end

------------------------------------------------------------------------
-- Non-interactive spawn (MCP spawn_agent)
------------------------------------------------------------------------

--- Called from the MCP server via RPC. Semantics, in order:
---   1. a running session with this name → error
---   2. an exited session with this name → relaunch it
---   3. a workspace member with no session → create + launch
---   4. otherwise define the agent in the library's "spawned" section if it
---      does not exist (system_prompt and role required for that), add it
---      to the live workspace, launch it
--- @return table  { success = boolean, error? = string, relaunched? = boolean }
function M.spawn(name, system_prompt, role, user_notes)
	local cwd = vim.fn.getcwd()
	local ws = workspace_mod()
	local sm = session_mod()
	local am = agent_mod()

	local ok_name, name_err = am.validate_name(name)
	if not ok_name then
		return { success = false, error = name_err }
	end

	local m = ws.get_current()
	if not m then
		m = ws.read(ws.EPHEMERAL, cwd) or ws.new_manifest(ws.EPHEMERAL)
		ws.save(m, cwd)
		ws.set_current(m)
		ws.init_runtime(cwd)
	end

	local sess = sm.get_by_name(name)
	if sess and sm.is_running(sess) then
		return { success = false, error = "agent '" .. name .. "' is already running" }
	end
	if sess then
		write_initial_status(sess, cwd, "relaunching")
		vim.defer_fn(function()
			terminal().open(sess.id)
		end, 100)
		return { success = true, relaunched = true }
	end

	local entry = ws.find_entry(m, name)
	if not entry then
		if not am.exists(name) then
			if not system_prompt or system_prompt == "" or not role or role == "" then
				return {
					success = false,
					error = "agent '" .. name .. "' does not exist; system_prompt and role are required to define it",
				}
			end
			local ok, err = am.create(name, {
				role = role,
				system_prompt = system_prompt,
				user_notes = (user_notes and user_notes ~= "") and user_notes or nil,
				spawned = true,
			})
			if not ok then
				return { success = false, error = err }
			end
		end
		local ok, err = ws.add_entry(m, { agent = name, name = name }, cwd)
		if not ok then
			return { success = false, error = err }
		end
		entry = ws.find_entry(m, name)
	end

	sess = create_session_for_entry(m, entry, cwd)
	if not sess then
		return { success = false, error = "failed to create session for '" .. name .. "'" }
	end
	vim.defer_fn(function()
		terminal().open(sess.id)
	end, 300)
	notify("agent '" .. name .. "' spawned into workspace '" .. m.name .. "'")
	return { success = true }
end

return M
