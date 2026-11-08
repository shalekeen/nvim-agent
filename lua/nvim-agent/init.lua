local M = {}

local config = require("nvim-agent.config")

local function launcher()
	return require("nvim-agent.launcher")
end

function M.setup(opts)
	-- Hard dependencies: bail early with a clear message rather than failing
	-- later from inside a pcall'd integration point.
	if not pcall(require, "which-key") then
		error("nvim-agent: which-key.nvim is required but not found", 2)
	end
	if not pcall(require, "barbar") then
		error("nvim-agent: barbar.nvim is required but not found", 2)
	end

	config.setup(opts)

	local cfg = config.get()
	vim.fn.mkdir(cfg.base_dir, "p")
	vim.fn.mkdir(cfg.base_dir .. "/agents", "p")

	local adapter_mod = require("nvim-agent.adapter")
	if cfg.adapter then
		local resolved = adapter_mod.resolve(cfg.adapter)
		adapter_mod.set_active(resolved)
		resolved:setup()
	end

	require("nvim-agent.commands").register()
	require("nvim-agent.autocmds").register()
	require("nvim-agent.keymaps").register()

	if cfg.auto_open then
		vim.defer_fn(function()
			M.startup()
		end, 100)
	end
end

------------------------------------------------------------------------
-- Startup / terminal
------------------------------------------------------------------------

--- Startup picker (resume ephemeral / new / load). Also what :NvimAgent
--- does when no workspace is live.
function M.startup()
	launcher().startup(vim.fn.getcwd())
end

function M.open()
	if not require("nvim-agent.session").get_current() then
		return M.startup()
	end
	require("nvim-agent.terminal").open()
end

function M.close()
	require("nvim-agent.terminal").close()
end

function M.toggle()
	if not require("nvim-agent.session").get_current() then
		return M.startup()
	end
	require("nvim-agent.terminal").toggle()
end

function M.refresh_context()
	local sess = require("nvim-agent.session").get_current()
	if sess then
		require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)
		vim.notify("nvim-agent: context refreshed", vim.log.levels.INFO)
	end
end

------------------------------------------------------------------------
-- Workspaces
------------------------------------------------------------------------

function M.workspace_new()
	launcher().new_workspace()
end
function M.workspace_load(name)
	launcher().load_workspace(name)
end
function M.workspace_list()
	launcher().list_workspaces_ui()
end
function M.workspace_remove(name)
	launcher().remove_workspace(name)
end
function M.workspace_rename(old, new)
	launcher().rename_workspace(old, new)
end
function M.workspace_save_as(name)
	launcher().save_workspace_as(name)
end

------------------------------------------------------------------------
-- Agents: workspace membership
------------------------------------------------------------------------

function M.agent_add(agent_name, session_name)
	launcher().add_agent(agent_name, session_name)
end
function M.agent_remove(name)
	launcher().remove_agent(name)
end
function M.agent_restart(name)
	launcher().restart_agent(name)
end
function M.agent_stop(name)
	launcher().stop_agent(name)
end

------------------------------------------------------------------------
-- Agents: global library
------------------------------------------------------------------------

function M.agent_define()
	launcher().define_agent()
end
function M.agent_edit(name)
	launcher().edit_agent(name)
end
function M.agent_copy(src, dst)
	launcher().copy_agent(src, dst)
end
function M.agent_delete(name)
	launcher().delete_agent(name)
end
function M.agent_list()
	launcher().list_agents_ui()
end

--- Push a session's current files to its GLOBAL agent and clear this
--- workspace's overrides for it. Edits from a live session otherwise stay
--- as workspace overrides.
function M.agent_push(name)
	launcher().push_agent(name)
end
--- Show which definition files each member overrides in the live workspace.
function M.agent_overrides()
	launcher().show_overrides_ui()
end
--- Drop one or all overrides for a member and reload from the global agent.
function M.agent_reset(name, file)
	launcher().reset_overrides(name, file)
end

--- Non-interactive spawn, called from the MCP server over RPC.
function M.spawn_agent_noninteractive(name, system_prompt, role, user_notes)
	return launcher().spawn(name, system_prompt, role, user_notes)
end

------------------------------------------------------------------------
-- Sessions
------------------------------------------------------------------------

function M.session_list()
	launcher().list_sessions_ui()
end
function M.session_switch(name)
	local n = tonumber(name)
	if n then
		return launcher().jump_session(n)
	end
	launcher().switch_session(name)
end
function M.session_jump(n)
	launcher().jump_session(n)
end
--- Type a line into a member's terminal.
function M.send_message(name, text)
	launcher().message_agent(name, text)
end
--- Floating overview of every member: state, role, task, mail, overrides.
function M.team_status()
	launcher().team_status()
end
--- Arrange every running agent in a uniform grid (≤ terminal.grid_columns
--- per row, default 4), re-flowing in place on repeat / hide every agent
--- window.
function M.arrange_all()
	local n = require("nvim-agent.terminal").arrange_all()
	if n > 0 then
		vim.notify(string.format("nvim-agent: arranged %d agent%s", n, n == 1 and "" or "s"), vim.log.levels.INFO)
	end
end
M.open_all = M.arrange_all
function M.close_all()
	local n = require("nvim-agent.terminal").hide_all()
	vim.notify(string.format("nvim-agent: hid %d agent window%s", n, n == 1 and "" or "s"), vim.log.levels.INFO)
end
function M.pick_session(prompt, callback)
	launcher().pick_session(prompt, callback)
end

------------------------------------------------------------------------
-- Context files of a session (active_dir mirrors the agent)
------------------------------------------------------------------------

local function current_active_dir()
	local sess = require("nvim-agent.session").get_current()
	return sess and sess.active_dir
end

--- Record `file` in whichever session owns `active_dir` as a workspace
--- override. Used after programmatic writes (dir add/remove, note keymaps)
--- that don't go through the BufWritePost autocmd.
--- @param active_dir string
--- @param file string  one of agent.AGENT_FILES
function M.sync_session(active_dir, file)
	local sess = require("nvim-agent.session").get_by_active_dir(active_dir)
	if sess then
		launcher().sync_session_file(sess, file, true)
	end
end

local function edit_context_file(active_dir, filename)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	vim.cmd("edit " .. vim.fn.fnameescape(active_dir .. "/" .. filename))
end

local function view_context_file(active_dir, filename, title, filetype, edit_fn)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	require("nvim-agent.ui").view_file(active_dir .. "/" .. filename, {
		title = title,
		filetype = filetype,
		on_edit = function()
			edit_fn(active_dir)
		end,
	})
end

function M.edit_system_prompt(active_dir)
	edit_context_file(active_dir, config.get().context_files.system_prompt)
end
function M.view_system_prompt(active_dir)
	view_context_file(active_dir, config.get().context_files.system_prompt, "System Prompt (Read-Only)", "markdown", M.edit_system_prompt)
end

function M.edit_user_notes(active_dir)
	edit_context_file(active_dir, config.get().context_files.user_notes)
end
function M.view_user_notes(active_dir)
	view_context_file(active_dir, config.get().context_files.user_notes, "User Notes (Read-Only)", "markdown", M.edit_user_notes)
end

function M.edit_persistent_dirs(active_dir)
	edit_context_file(active_dir, config.get().context_files.persistent_dirs)
end
function M.view_persistent_dirs(active_dir)
	view_context_file(active_dir, config.get().context_files.persistent_dirs, "Persistent Dirs (Read-Only)", "json", M.edit_persistent_dirs)
end

--- The role guides the agent and is what peers see when delegating.
function M.edit_role(active_dir)
	edit_context_file(active_dir, "role.md")
end
function M.view_role(active_dir)
	view_context_file(active_dir, "role.md", "Role (Read-Only)", "markdown", M.edit_role)
end

function M.add_persistent_dir(tag, path, description, active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	local dirs_path = active_dir .. "/" .. config.get().context_files.persistent_dirs
	local dirs_mod = require("nvim-agent.context.persistent_dirs")
	local entries = dirs_mod.load(dirs_path)
	local replaced = false
	for i, entry in ipairs(entries) do
		if entry.tag == tag then
			entries[i] = { tag = tag, path = path, description = description }
			replaced = true
			break
		end
	end
	if not replaced then
		table.insert(entries, { tag = tag, path = path, description = description })
	end
	dirs_mod.save(entries, dirs_path)
	M.sync_session(active_dir, config.get().context_files.persistent_dirs)
	vim.notify("nvim-agent: added directory '" .. tag .. "'", vim.log.levels.INFO)
end

function M.remove_persistent_dir(tag, active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	local dirs_path = active_dir .. "/" .. config.get().context_files.persistent_dirs
	local dirs_mod = require("nvim-agent.context.persistent_dirs")
	local entries = dirs_mod.load(dirs_path)
	for i, entry in ipairs(entries) do
		if entry.tag == tag then
			table.remove(entries, i)
			dirs_mod.save(entries, dirs_path)
			M.sync_session(active_dir, config.get().context_files.persistent_dirs)
			vim.notify("nvim-agent: removed directory '" .. tag .. "'", vim.log.levels.INFO)
			return
		end
	end
	vim.notify("nvim-agent: directory '" .. tag .. "' not found", vim.log.levels.WARN)
end

------------------------------------------------------------------------
-- Tmux captures (shared per instance via process_dir)
------------------------------------------------------------------------

function M.tmux_add_capture(lines)
	local tmux = require("nvim-agent.context.tmux_capture")
	if not tmux.is_tmux() then
		return vim.notify("nvim-agent: not running inside tmux", vim.log.levels.WARN)
	end
	local sess = require("nvim-agent.session").get_current()
	if not sess then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	local panes = tmux.list_panes()
	if #panes == 0 then
		return vim.notify("nvim-agent: no other tmux panes found", vim.log.levels.INFO)
	end
	local options = {}
	for _, p in ipairs(panes) do
		table.insert(options, p.display)
	end
	require("nvim-agent.ui").select(options, { prompt = "Capture tmux pane", width = 70 }, function(choice, idx)
		if not choice or not idx then
			return
		end
		local pane = panes[idx]
		local capture, err = tmux.add_capture(sess.process_dir, pane.pane_id, pane.display, lines)
		if capture then
			vim.notify(
				string.format("nvim-agent: captured pane %s (%d lines)", pane.display, capture.line_count),
				vim.log.levels.INFO
			)
		else
			vim.notify("nvim-agent: capture failed: " .. (err or "unknown"), vim.log.levels.ERROR)
		end
	end)
end

function M.tmux_clear_captures()
	local sess = require("nvim-agent.session").get_current()
	if not sess then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	require("nvim-agent.context.tmux_capture").clear(sess.process_dir)
	vim.notify("nvim-agent: tmux captures cleared", vim.log.levels.INFO)
end

function M.tmux_view_captures()
	local sess = require("nvim-agent.session").get_current()
	if not sess then
		return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
	end
	local path = sess.process_dir .. "/" .. config.get().context_files.tmux_captures
	if vim.fn.filereadable(path) == 1 then
		vim.cmd("vsplit " .. vim.fn.fnameescape(path))
	else
		vim.notify("nvim-agent: no tmux captures found", vim.log.levels.INFO)
	end
end

------------------------------------------------------------------------
-- History (per-instance work logs)
------------------------------------------------------------------------

local function open_history_scratch(title, files)
	local lines = {}
	local found = false
	for _, f in ipairs(files) do
		local fh = io.open(f.path, "r")
		if fh then
			found = true
			table.insert(lines, string.rep("=", 60))
			table.insert(lines, "## " .. f.name)
			table.insert(lines, string.rep("=", 60))
			for line in fh:lines() do
				table.insert(lines, line)
			end
			fh:close()
			table.insert(lines, "")
		end
	end
	if not found then
		return vim.notify("nvim-agent: no history files found", vim.log.levels.INFO)
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, title)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end

--- History for one agent in this instance (picker when name is nil).
function M.history_view_agent(name)
	local cwd = vim.fn.getcwd()
	local history_dir = require("nvim-agent.workspace").instance_runtime_dir(cwd) .. "/history"

	if name then
		local path = history_dir .. "/" .. name .. ".md"
		if vim.fn.filereadable(path) == 0 then
			return vim.notify("nvim-agent: no history for agent '" .. name .. "'", vim.log.levels.INFO)
		end
		return open_history_scratch("Agent History: " .. name, { { name = name, path = path } })
	end

	local seen, candidates = {}, {}
	for _, sess in ipairs(require("nvim-agent.session").list()) do
		if not seen[sess.name] then
			seen[sess.name] = true
			table.insert(candidates, sess.name)
		end
	end
	for _, p in ipairs(vim.fn.glob(history_dir .. "/*.md", false, true)) do
		local n = vim.fn.fnamemodify(p, ":t:r")
		if not seen[n] then
			seen[n] = true
			table.insert(candidates, n)
		end
	end
	if #candidates == 0 then
		return vim.notify("nvim-agent: no agent history found", vim.log.levels.INFO)
	end
	if #candidates == 1 then
		return M.history_view_agent(candidates[1])
	end
	require("nvim-agent.ui").select(candidates, { prompt = "View history for agent", width = 70 }, function(choice)
		if choice then
			M.history_view_agent(choice)
		end
	end)
end

--- History for every member of the live workspace, in this instance.
function M.history_view_workspace()
	local cwd = vim.fn.getcwd()
	local ws = require("nvim-agent.workspace")
	local m = ws.get_current()
	if not m then
		return vim.notify("nvim-agent: no live workspace", vim.log.levels.WARN)
	end
	local history_dir = ws.instance_runtime_dir(cwd) .. "/history"
	local files = {}
	for _, e in ipairs(m.agents or {}) do
		table.insert(files, { name = e.name, path = history_dir .. "/" .. e.name .. ".md" })
	end
	open_history_scratch("Workspace History: " .. m.name, files)
end

--- History across every Neovim instance that has ever run in this project.
--- Agents only ever see their own instance; this view stitches them together.
function M.history_view_project()
	local cwd = vim.fn.getcwd()
	local instances_dir = require("nvim-agent.workspace").runtime_dir(cwd) .. "/instances"
	local paths = vim.fn.glob(instances_dir .. "/*/history/*.md", false, true)
	if #paths == 0 then
		return vim.notify("nvim-agent: no history files found in project", vim.log.levels.INFO)
	end
	local files = {}
	for _, p in ipairs(paths) do
		local agent_name = vim.fn.fnamemodify(p, ":t:r")
		local instance_id = vim.fn.fnamemodify(p, ":h:h:t")
		table.insert(files, { name = agent_name .. "  (instance " .. instance_id:sub(1, 8) .. ")", path = p })
	end
	open_history_scratch("Project History", files)
end

------------------------------------------------------------------------
-- Misc
------------------------------------------------------------------------

function M.adapter_setup()
	local adapter = require("nvim-agent.adapter").get_active()
	if not adapter then
		return vim.notify("nvim-agent: no adapter configured", vim.log.levels.ERROR)
	end
	adapter:setup()
end

--- Graceful quit: sync every session to its agent, confirm if agents are
--- running, then quit.
function M.graceful_quit()
	local session_mod = require("nvim-agent.session")
	local sessions = session_mod.list()
	local running = {}
	for _, sess in ipairs(sessions) do
		if sess.jobid then
			table.insert(running, sess.name)
		end
	end

	local function do_quit()
		-- Nothing to persist: every edit already landed in its workspace override.
		vim.cmd("qa!")
	end

	if #running == 0 then
		return do_quit()
	end
	require("nvim-agent.ui").select({ "Quit (stops running agents)", "Cancel" }, {
		prompt = string.format("%d agent(s) still running: %s", #running, table.concat(running, ", ")),
		width = 70,
	}, function(choice)
		if choice and choice:match("^Quit") then
			do_quit()
		end
	end)
end

--- Statusline component: "Agent-<session>: <agent> @ <workspace>", with an
--- "(exited)" suffix when the CLI is not running. Empty when no session.
function M.statusline()
	local ok, session_mod = pcall(require, "nvim-agent.session")
	if not ok then
		return ""
	end
	local sess = session_mod.get_current()
	if not sess then
		return ""
	end
	local ws = require("nvim-agent.workspace").get_current()
	local s = string.format("Agent-%s: %s%s @ %s", sess.name, sess.agent or "?", sess.overrides and "+" or "", ws and ws.name or "?")
	if not session_mod.is_running(sess) then
		s = s .. " (exited)"
	end
	return s
end

return M
