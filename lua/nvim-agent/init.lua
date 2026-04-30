local M = {}

local config = require("nvim-agent.config")

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

	vim.fn.mkdir(config.get().base_dir, "p")

	-- Resolve adapter
	local adapter_mod = require("nvim-agent.adapter")
	local cfg = config.get()

	if cfg.adapter then
		local resolved = adapter_mod.resolve(cfg.adapter)
		adapter_mod.set_active(resolved)
		resolved:setup()
	end

	require("nvim-agent.commands").register()
	require("nvim-agent.autocmds").register()
	require("nvim-agent.keymaps").register()

	-- On startup, auto-launch the previous flavor (if recorded) only when
	-- auto_open is enabled. Otherwise the user must trigger :NvimAgent
	-- manually, which goes through the full picker.
	if cfg.auto_open then
		vim.defer_fn(function()
			M.auto_launch()
		end, 100)
	end
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

--- Persist the last-used flavor/checkpoint to ~/.nvim-agent/last_flavor.json.
--- Powers the "Use Active - <flavor>" default option on next startup.
--- (Sessions are ephemeral; this file is the only cross-restart persistence.)
local function persist_flavor_choice(flavor_name, checkpoint_name)
	local meta = { flavor = flavor_name, checkpoint = checkpoint_name }
	local path = config.get().base_dir .. "/last_flavor.json"
	local f = io.open(path, "w")
	if f then
		f:write(vim.json.encode(meta))
		f:close()
	end
end

--- Read the last-used flavor/checkpoint from ~/.nvim-agent/last_flavor.json.
--- @return string|nil flavor_name
--- @return string|nil checkpoint_name
local function read_last_flavor()
	local path = config.get().base_dir .. "/last_flavor.json"
	local f = io.open(path, "r")
	if not f then
		return nil, nil
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		return data.flavor, data.checkpoint
	end
	return nil, nil
end

--- Create a session for the given flavor+checkpoint, populate its active_dir,
--- then focus NvimTree and optionally auto-open the terminal.
--- @param flavor_name string
--- @param checkpoint_name string|nil
--- @param session_name string|nil  nil → auto-"main" for first session
local function create_and_open_session(flavor_name, checkpoint_name, session_name)
	local session_mod = require("nvim-agent.session")
	local flavor = require("nvim-agent.flavor")

	local sess, err = session_mod.create(flavor_name, checkpoint_name, session_name)
	if not sess then
		vim.notify("nvim-agent: " .. (err or "failed to create session"), vim.log.levels.ERROR)
		return nil
	end

	-- Populate the session's active_dir from the chosen flavor/checkpoint
	if checkpoint_name then
		require("nvim-agent.flavor.checkpoint").load(flavor_name, checkpoint_name, sess.active_dir)
	else
		flavor.load(flavor_name, nil, sess.active_dir)
	end

	-- Persist choice to global active dir so "Use Active" shows correctly next startup
	persist_flavor_choice(flavor_name, checkpoint_name)

	focus_nvim_tree()
	-- Always open the terminal: this path is always user-initiated.
	vim.defer_fn(function()
		require("nvim-agent.terminal").open(sess.id)
	end, 300)
	return sess
end

--- Startup auto-launch path. When a previous flavor was recorded AND that
--- flavor still exists, skip the picker and launch it. Otherwise fall
--- through to the full workspace + standalone picker so the user can re-pick.
function M.auto_launch()
	local last_flavor, last_checkpoint = read_last_flavor()
	if last_flavor and require("nvim-agent.flavor").list_contains(last_flavor) then
		create_and_open_session(last_flavor, last_checkpoint, nil)
		return
	end
	M.ensure_active_flavor()
end

--- Show the flavor + checkpoint picker for a new session with an already-chosen name.
--- Includes a "Use Active" shortcut when a last-used flavor/checkpoint is stored.
--- @param session_name string|nil  nil → auto-"main" for the first session
function M.pick_and_create_session(session_name)
	local ui = require("nvim-agent.ui")
	local flavor = require("nvim-agent.flavor")
	local flavors = flavor.list()

	if #flavors == 0 then
		ui.input({ prompt = "", title = "Create New Flavor (Name)" }, function(fname)
			if not fname or fname == "" then
				return
			end
			flavor.create(fname)
			M.select_checkpoint_for_session(fname, session_name)
		end)
		return
	end

	local options = {}
	local opt_map = {}

	-- "Use Active" shortcut: one-click restore of the last-used flavor + checkpoint.
	local last_flavor, last_checkpoint = read_last_flavor()
	if last_flavor then
		local cp_label = last_checkpoint and ("@ " .. last_checkpoint) or "@ base"
		local active_label = "Use Active  —  " .. last_flavor .. "  " .. cp_label
		table.insert(options, active_label)
		opt_map[active_label] = { flavor = last_flavor, checkpoint = last_checkpoint, use_active = true }
	end

	for _, f in ipairs(flavors) do
		if f ~= last_flavor then -- "Use Active" already covers last_flavor
			table.insert(options, f)
			opt_map[f] = { flavor = f }
		end
	end
	table.insert(options, "Create new flavor")

	ui.select(options, { prompt = "Select flavor for new session", width = 70 }, function(choice)
		if not choice then
			return
		end

		if choice == "Create new flavor" then
			ui.input({ prompt = "", title = "Create New Flavor (Name)" }, function(fname)
				if not fname or fname == "" then
					return
				end
				flavor.create(fname)
				M.select_checkpoint_for_session(fname, session_name)
			end)
			return
		end

		local sel = opt_map[choice]
		if not sel then
			return
		end

		if sel.use_active then
			create_and_open_session(sel.flavor, sel.checkpoint, session_name)
		else
			M.select_checkpoint_for_session(sel.flavor, session_name)
		end
	end)
end

--- Show checkpoint picker for a named flavor, then create the session.
--- @param flavor_name string
--- @param session_name string|nil
function M.select_checkpoint_for_session(flavor_name, session_name)
	local ui = require("nvim-agent.ui")
	local checkpoint = require("nvim-agent.flavor.checkpoint")
	local checkpoints = checkpoint.list(flavor_name)

	local options = { "base (default)" }
	for _, cp in ipairs(checkpoints) do
		table.insert(options, cp)
	end

	ui.select(options, {
		prompt = "Select checkpoint for '" .. flavor_name .. "'",
		width = 70,
	}, function(choice)
		if not choice or choice == "base (default)" then
			vim.notify("Using base for flavor: " .. flavor_name, vim.log.levels.INFO)
			create_and_open_session(flavor_name, nil, session_name)
		else
			vim.notify("Loaded checkpoint: " .. choice, vim.log.levels.INFO)
			create_and_open_session(flavor_name, choice, session_name)
		end
	end)
end

--- Called on startup. Shows a picker that covers both operating modes:
---   Mode 1 (standalone): select or create a global flavor/checkpoint — no project files.
---   Mode 2 (workspace):  launch a multi-agent workspace defined in <def_dir>/.
--- Workspace options appear first when a workspace is detected in the current directory.
function M.ensure_active_flavor()
	local ui = require("nvim-agent.ui")
	local flavor = require("nvim-agent.flavor")
	local workspace_mod = require("nvim-agent.workspace")
	local cwd = vim.fn.getcwd()

	-- Mode 2: discover project workspaces from the definition directory.
	local has_ws = workspace_mod.has_workspace(cwd)
	local workspaces = has_ws and workspace_mod.workspace_list(cwd) or {}

	-- If nothing exists at all (no workspace, no flavors), bootstrap a new flavor (Mode 1).
	local flavors = flavor.list()
	if #flavors == 0 and #workspaces == 0 and not has_ws then
		ui.input({ prompt = "", title = "Create New Flavor (Name)" }, function(name)
			if not name or name == "" then
				return
			end
			flavor.create(name)
			M.select_checkpoint_for_session(name)
		end)
		return
	end

	local options = {}
	local flavor_map = {}

	-- Workspace options first (Mode 2).
	for _, ws in ipairs(workspaces) do
		local agent_names = {}
		for _, a in ipairs(ws.agents or {}) do
			table.insert(agent_names, a.name)
		end
		local label = string.format("Launch workspace '%s'  [%s]", ws.name, table.concat(agent_names, ", "))
		table.insert(options, label)
		flavor_map[label] = { workspace = ws }
	end

	-- Workspace management options when workspace dir is initialized.
	if has_ws then
		local new_ws_label = "Create new workspace definition"
		table.insert(options, new_ws_label)
		flavor_map[new_ws_label] = { new_workspace = true }
	end

	-- Initialize workspace option when no workspace exists yet.
	if not has_ws then
		table.insert(options, "Initialize project workspace (multi-agent mode)")
		flavor_map["Initialize project workspace (multi-agent mode)"] = { init_workspace = true }
	end

	-- Standalone agent option (Mode 1) — always available even when a workspace exists.
	table.insert(options, "Open standalone agent (flavor / checkpoint)")
	flavor_map["Open standalone agent (flavor / checkpoint)"] = { standalone = true }

	ui.select(options, { prompt = "nvim-agent", width = 70 }, function(choice)
		if not choice then
			return
		end

		local selected = flavor_map[choice]
		if not selected then
			return
		end

		if selected.init_workspace then
			M.workspace_init()
		elseif selected.new_workspace then
			M.workspace_new()
		elseif selected.workspace then
			M.workspace_launch(selected.workspace, cwd)
		elseif selected.standalone then
			-- Drop into the classic flavor + checkpoint picker.
			M.pick_and_create_session(nil)
		end
	end)
end

--- Create a new session. Prompts for a session name first (required for 2nd+ sessions),
--- then shows the flavor + checkpoint picker.
function M.new_session()
	local session_mod = require("nvim-agent.session")
	local sessions = session_mod.list()

	if #sessions > 0 then
		-- Subsequent sessions require a user-provided name
		local ui = require("nvim-agent.ui")
		ui.input({ prompt = "", title = "Session Name" }, function(session_name)
			if not session_name or session_name == "" then
				return
			end
			M.pick_and_create_session(session_name)
		end)
	else
		-- First session auto-gets "main"
		M.pick_and_create_session(nil)
	end
end

--- Show a picker to switch between open sessions.
function M.session_list_picker()
	local ui = require("nvim-agent.ui")
	local session_mod = require("nvim-agent.session")
	local sessions = session_mod.list()

	if #sessions == 0 then
		vim.notify("nvim-agent: no active sessions", vim.log.levels.INFO)
		return
	end

	local options = {}
	for _, sess in ipairs(sessions) do
		local cp = sess.checkpoint and ("@ " .. sess.checkpoint) or "@ base"
		local marker = (sess.id == session_mod.current_id) and " *" or ""
		table.insert(options, string.format("%s: %s %s%s", sess.name, sess.flavor, cp, marker))
	end

	ui.select(options, { prompt = "Switch to session", width = 70 }, function(choice)
		if not choice then
			return
		end
		local sname = choice:match("^([^:]+):")
		if not sname then
			return
		end
		sname = sname:match("^%s*(.-)%s*$")
		local sess = session_mod.get_by_name(sname)
		if sess then
			require("nvim-agent.terminal").open(sess.id)
		end
	end)
end

--- Display active sessions via notify.
function M.session_list()
	local session_mod = require("nvim-agent.session")
	local sessions = session_mod.list()
	if #sessions == 0 then
		vim.notify("nvim-agent: no active sessions", vim.log.levels.INFO)
		return
	end
	local lines = {}
	for _, sess in ipairs(sessions) do
		local cp = sess.checkpoint and ("@ " .. sess.checkpoint) or "@ base"
		local marker = (sess.id == session_mod.current_id) and " *" or ""
		table.insert(lines, string.format("  %s: %s %s%s", sess.name, sess.flavor, cp, marker))
	end
	vim.notify("nvim-agent sessions:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Close a specific session by name (or current session if name is nil).
--- @param name string|nil  session name (e.g. "main", "research")
function M.session_close(name)
	local session_mod = require("nvim-agent.session")
	local sess = (name and name ~= "") and session_mod.get_by_name(name) or session_mod.get_current()
	if not sess then
		vim.notify("nvim-agent: no session to close", vim.log.levels.WARN)
		return
	end
	local display_name = sess.name
	session_mod.close(sess.id)
	vim.notify("nvim-agent: closed session '" .. display_name .. "'", vim.log.levels.INFO)
end

--- Show a flavor picker for a workspace agent.
--- Lists global flavors and existing workspace agents (as copy-from templates).
--- Calls on_done({ type, flavor?, checkpoint?, source_agent? }) or { type="def_only" }.
--- @param agent_name string
--- @param cwd string
--- @param on_done function
local function pick_flavor_for_ws_agent(agent_name, cwd, on_done)
	local ui = require("nvim-agent.ui")
	local flavor_mod = require("nvim-agent.flavor")
	local workspace_mod = require("nvim-agent.workspace")

	local global_flavors = flavor_mod.list()
	local ws_agents = workspace_mod.agent_list(cwd)
	local agent_templates = workspace_mod.template_list()

	local options = { "Agent definition only" }
	local opt_map = { ["Agent definition only"] = { type = "def_only" } }

	-- Global agent templates
	for _, t in ipairs(agent_templates) do
		local label = "Template: " .. t
		table.insert(options, label)
		opt_map[label] = { type = "agent_template", template = t }
	end

	-- Global flavors
	for _, f in ipairs(global_flavors) do
		local label = "Flavor: " .. f
		table.insert(options, label)
		opt_map[label] = { type = "global", flavor = f }
	end

	-- Copy from existing workspace agent
	for _, a in ipairs(ws_agents) do
		if a.name ~= agent_name then
			local label = "Copy from agent: " .. a.name
			table.insert(options, label)
			opt_map[label] = { type = "template", source_agent = a.name }
		end
	end

	ui.select(options, {
		prompt = string.format("Context for agent '%s'", agent_name),
		width = 80,
	}, function(choice)
		if not choice then
			on_done({ type = "def_only" })
			return
		end
		local sel = opt_map[choice]
		if not sel then
			on_done({ type = "def_only" })
			return
		end
		if sel.type == "global" then
			local checkpoint_mod = require("nvim-agent.flavor.checkpoint")
			local cps = checkpoint_mod.list(sel.flavor)
			if #cps == 0 then
				on_done({ type = "global", flavor = sel.flavor, checkpoint = nil })
			else
				local cp_opts = { "base (default)" }
				for _, cp in ipairs(cps) do
					table.insert(cp_opts, cp)
				end
				ui.select(cp_opts, {
					prompt = "Checkpoint for '" .. sel.flavor .. "'",
					width = 70,
				}, function(cp_choice)
					local cp = (cp_choice and cp_choice ~= "base (default)") and cp_choice or nil
					on_done({ type = "global", flavor = sel.flavor, checkpoint = cp })
				end)
			end
		else
			on_done(sel)
		end
	end)
end

--- Apply a flavor selection to a workspace agent's active_dir and persist back to def dir.
--- @param agent_name string
--- @param active_dir string  session active_dir
--- @param sel table  { type, flavor?, checkpoint?, source_agent? }
--- @param cwd string
local function apply_ws_flavor(agent_name, active_dir, sel, cwd)
	local workspace_mod = require("nvim-agent.workspace")
	if sel.type == "global" then
		local flavor_mod = require("nvim-agent.flavor")
		local checkpoint_mod = require("nvim-agent.flavor.checkpoint")
		if sel.checkpoint then
			checkpoint_mod.load(sel.flavor, sel.checkpoint, active_dir)
		else
			flavor_mod.load(sel.flavor, nil, active_dir)
		end
		-- Overlay def dir content on top (def dir wins for any existing files)
		workspace_mod.agent_load_content(agent_name, active_dir, cwd)
		-- Persist the merged result back so the agent retains this flavor choice
		workspace_mod.agent_save_content(agent_name, active_dir, cwd)
	elseif sel.type == "template" then
		-- Copy files from another agent's def dir into this agent's def dir
		local src_dir = workspace_mod.agent_content_dir(sel.source_agent, cwd)
		local dest_dir = workspace_mod.agent_content_dir(agent_name, cwd)
		if src_dir and dest_dir then
			local files = {
				"system_prompt.md",
				"user_notes.md",
				"persistent_dirs.json",
				".flavor_meta.json",
				"role.md",
				"permissions.json",
			}
			for _, f in ipairs(files) do
				local src = src_dir .. "/" .. f
				if vim.fn.filereadable(src) == 1 then
					vim.fn.writefile(vim.fn.readfile(src), dest_dir .. "/" .. f)
				end
			end
		end
		workspace_mod.agent_load_content(agent_name, active_dir, cwd)
	elseif sel.type == "agent_template" then
		-- Load from a global agent template, then overlay agent def dir on top
		workspace_mod.template_load(sel.template, active_dir)
		-- Link the agent to the template for future reference
		workspace_mod.agent_set_template(agent_name, sel.template, cwd)
		-- Overlay agent-specific files (if any exist in the def dir)
		workspace_mod.agent_load_content(agent_name, active_dir, cwd)
		-- Persist merged result back to agent def dir
		workspace_mod.agent_save_content(agent_name, active_dir, cwd)
	else
		-- def_only: the agent definition directory in cwd is the source of truth.
		-- Load it into active_dir, then label the session with the agent's name
		-- via .flavor_meta.json. We deliberately do NOT plant a global flavor at
		-- ~/.nvim-agent/<agent_name>/ — that pollutes flavor.list() with names
		-- of every workspace agent the user has ever launched.
		local flavor_mod = require("nvim-agent.flavor")
		workspace_mod.agent_load_content(agent_name, active_dir, cwd)
		flavor_mod.write_meta(agent_name, nil, active_dir)
	end
end

--- Launch all agents in a workspace. Reads agent definitions from the project's
--- definition directory (<def_dir>/agents/<name>/) and starts a session per agent.
--- Agents with no stored .flavor_meta.json are shown a flavor picker before launch.
--- Agents are processed sequentially so pickers don't overlap.
--- @param workspace table  { name, agents: [{name, role}] }
--- @param cwd string|nil  Project directory (defaults to vim.fn.getcwd())
function M.workspace_launch(workspace, cwd)
	cwd = cwd or vim.fn.getcwd()
	local session_mod = require("nvim-agent.session")
	local workspace_mod = require("nvim-agent.workspace")
	local agent_entries = workspace.agents or {}

	-- Write .claude/settings.json in the project dir so agents don't get
	-- interrupted by permission prompts on every file/bash operation.
	local adapter = require("nvim-agent.adapter").get_active()
	if adapter and adapter.setup_project_permissions then
		adapter:setup_project_permissions(cwd)
	end

	if #agent_entries == 0 then
		vim.notify("nvim-agent: workspace has no agents configured", vim.log.levels.WARN)
		return
	end

	workspace_mod.init_runtime(cwd)

	local created = {}

	local function finish()
		if #created == 0 then
			vim.notify("nvim-agent: no workspace agents could be created", vim.log.levels.ERROR)
			return
		end
		focus_nvim_tree()

		local session_ids = {}
		for _, sess in ipairs(created) do
			table.insert(session_ids, sess.id)
		end

		-- Use grid layout for multi-agent workspaces (4 columns),
		-- single split for solo agents.
		vim.defer_fn(function()
			if #session_ids > 1 then
				require("nvim-agent.terminal").open_grid(session_ids, 4)
			else
				require("nvim-agent.terminal").open(session_ids[1])
			end
		end, 300)

		vim.notify(
			string.format("nvim-agent: workspace '%s' launched (%d agents)", workspace.name or "unnamed", #created),
			vim.log.levels.INFO
		)
	end

	local function create_agent_session(entry, agent, sel, next_fn)
		local flavor_name = (sel.type == "global" and sel.flavor) or agent.name
		local checkpoint_name = (sel.type == "global") and sel.checkpoint or nil
		local sess, err = session_mod.create(flavor_name, checkpoint_name, agent.name)
		if not sess then
			vim.notify(
				"nvim-agent: failed to create agent '" .. entry.name .. "': " .. (err or "?"),
				vim.log.levels.ERROR
			)
			next_fn()
			return
		end

		apply_ws_flavor(agent.name, sess.active_dir, sel, cwd)

		-- Workspace-scoped role always wins over any role.md from the def dir.
		if entry.role and entry.role ~= "" then
			local rf = io.open(sess.active_dir .. "/role.md", "w")
			if rf then
				rf:write(entry.role)
				rf:close()
			end
		end

		-- Write initial status so peers can discover this agent immediately.
		local status_dir = workspace_mod.runtime_dir(cwd) .. "/status"
		vim.fn.mkdir(status_dir, "p")
		local status_path = status_dir .. "/" .. agent.name .. ".json"
		local sf = io.open(status_path, "w")
		if sf then
			sf:write(vim.json.encode({
				agent = agent.name,
				role = (entry.role and entry.role ~= "") and entry.role or nil,
				current_task = "launching",
				updated_at = os.date("%Y-%m-%dT%H:%M:%SZ"),
			}))
			sf:close()
		else
			vim.notify(
				"nvim-agent: failed to write initial status for '" .. agent.name .. "' at " .. status_path,
				vim.log.levels.WARN
			)
		end

		table.insert(created, sess)
		next_fn()
	end

	-- Process agents sequentially using a recursive closure.
	local function launch_agent(idx)
		if idx > #agent_entries then
			finish()
			return
		end

		local entry = agent_entries[idx]
		local agent = workspace_mod.agent_get(entry.name, cwd)

		if not agent then
			vim.notify(
				string.format("nvim-agent: agent '%s' not found in definition directory", entry.name),
				vim.log.levels.WARN
			)
			launch_agent(idx + 1)
			return
		end

		-- Agents that already have a stored flavor/checkpoint (from a prior session)
		-- skip the picker and load their definition directory as-is.
		local def_dir_path = workspace_mod.agent_content_dir(entry.name, cwd)
		local has_meta = def_dir_path ~= nil and vim.fn.filereadable(def_dir_path .. "/.flavor_meta.json") == 1

		if has_meta then
			create_agent_session(entry, agent, { type = "def_only" }, function()
				launch_agent(idx + 1)
			end)
		else
			pick_flavor_for_ws_agent(entry.name, cwd, function(sel)
				create_agent_session(entry, agent, sel, function()
					launch_agent(idx + 1)
				end)
			end)
		end
	end

	launch_agent(1)
end

--- Initialize a new workspace for the current project.
--- Prompts for a directory name (checked into git) that will hold agent + workspace definitions.
--- Also creates .nvim-agent/ (gitignored runtime dir) and writes config.json.
function M.workspace_init()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	if workspace_mod.has_workspace(cwd) then
		local dd = workspace_mod.def_dir(cwd)
		vim.notify("nvim-agent: workspace already initialized at " .. (dd or "?"), vim.log.levels.INFO)
		return
	end

	local default_name = ".nvim-workspace"
	ui.input(
		{ prompt = "", title = "Workspace definition directory (will be checked into git)", default = default_name },
		function(name)
			if not name or name == "" then
				return
			end
			local dd = workspace_mod.init(cwd, name)
			vim.notify(
				string.format(
					"nvim-agent: workspace initialized.\n  Definitions (git): %s/\n  Runtime (gitignored): %s/",
					dd,
					workspace_mod.runtime_dir(cwd)
				),
				vim.log.levels.INFO
			)
		end
	)
end

--- Snapshot all live sessions into agent definition dirs + save a named workspace.
function M.workspace_save()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized — run 'NvimAgent workspace init' first", vim.log.levels.WARN)
		return
	end

	local default_name = vim.fn.fnamemodify(cwd, ":t")
	ui.input({ prompt = "", title = "Workspace Name (default: " .. default_name .. ")" }, function(name)
		name = (name and name ~= "") and name or default_name
		workspace_mod.save_current_as(name, cwd)
	end)
end

--- Show a picker of project workspaces and delete the chosen one.
function M.workspace_remove()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	local workspaces = workspace_mod.workspace_list(cwd)

	if #workspaces == 0 then
		vim.notify("nvim-agent: no workspace definitions found", vim.log.levels.INFO)
		return
	end

	local options = {}
	for _, ws in ipairs(workspaces) do
		local count = #(ws.agents or {})
		table.insert(options, string.format("%s  [%d agent%s]", ws.name, count, count == 1 and "" or "s"))
	end

	ui.select(options, { prompt = "Remove workspace", width = 80 }, function(_, idx)
		if idx and workspaces[idx] then
			workspace_mod.workspace_delete(workspaces[idx].name, cwd)
		end
	end)
end

--- List all project workspaces and their agents.
function M.workspace_list()
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	local workspaces = workspace_mod.workspace_list(cwd)
	if #workspaces == 0 then
		vim.notify("nvim-agent: no workspace definitions found", vim.log.levels.INFO)
		return
	end
	local lines = {}
	for _, ws in ipairs(workspaces) do
		local agent_names = {}
		for _, a in ipairs(ws.agents or {}) do
			table.insert(agent_names, a.name)
		end
		table.insert(lines, string.format("  %s  [%s]", ws.name, table.concat(agent_names, ", ")))
	end
	vim.notify("nvim-agent workspaces:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Launch a workspace alongside any sessions already running. With no name,
--- shows a picker over existing manifests and offers a "create new" fallback;
--- if the project has no workspace yet, prompts to initialize one first.
--- @param name string|nil  Optional workspace manifest name to launch directly.
function M.workspace_launch_picker(name)
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	-- Direct launch by name: skip the picker entirely.
	if name and name ~= "" then
		if not workspace_mod.has_workspace(cwd) then
			vim.notify("nvim-agent: no workspace initialized in this directory", vim.log.levels.ERROR)
			return
		end
		for _, ws in ipairs(workspace_mod.workspace_list(cwd)) do
			if ws.name == name then
				M.workspace_launch(ws, cwd)
				return
			end
		end
		vim.notify("nvim-agent: workspace '" .. name .. "' not found in this project", vim.log.levels.ERROR)
		return
	end

	-- No workspace dir at all: bootstrap by initializing one, then drop into
	-- the manifest-creation flow.
	if not workspace_mod.has_workspace(cwd) then
		ui.input(
			{ prompt = "", title = "No workspace here yet — initialize one (directory name)", default = ".nvim-workspace" },
			function(dir_name)
				if not dir_name or dir_name == "" then
					return
				end
				local dd = workspace_mod.init(cwd, dir_name)
				vim.notify(
					string.format(
						"nvim-agent: workspace initialized.\n  Definitions (git): %s/\n  Runtime (gitignored): %s/",
						dd,
						workspace_mod.runtime_dir(cwd)
					),
					vim.log.levels.INFO
				)
				M.workspace_new()
			end
		)
		return
	end

	-- Workspace exists but no manifests yet: create the first one.
	local manifests = workspace_mod.workspace_list(cwd)
	if #manifests == 0 then
		vim.notify("nvim-agent: no workspaces defined yet — creating one", vim.log.levels.INFO)
		M.workspace_new()
		return
	end

	-- Show picker over existing manifests + a "create another" option.
	local options = {}
	local opt_map = {}
	for _, ws in ipairs(manifests) do
		local agent_names = {}
		for _, a in ipairs(ws.agents or {}) do
			table.insert(agent_names, a.name)
		end
		local label = string.format("%s  [%s]", ws.name, table.concat(agent_names, ", "))
		table.insert(options, label)
		opt_map[label] = ws
	end
	local create_label = "Create new workspace definition"
	table.insert(options, create_label)

	ui.select(options, { prompt = "Launch workspace", width = 80 }, function(choice)
		if not choice then
			return
		end
		if choice == create_label then
			M.workspace_new()
			return
		end
		M.workspace_launch(opt_map[choice], cwd)
	end)
end

--- Edit an existing workspace definition: add/remove agents, change roles.
--- Loads the workspace JSON, presents the same add/remove UI as workspace_new,
--- then saves the updated definition.
function M.workspace_edit()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized — run 'NvimAgent workspace init' first", vim.log.levels.WARN)
		return
	end

	local workspaces = workspace_mod.workspace_list(cwd)
	if #workspaces == 0 then
		vim.notify("nvim-agent: no workspace definitions found", vim.log.levels.INFO)
		return
	end

	local options = {}
	for _, ws in ipairs(workspaces) do
		local count = #(ws.agents or {})
		table.insert(options, string.format("%s  [%d agent%s]", ws.name, count, count == 1 and "" or "s"))
	end

	ui.select(options, { prompt = "Edit workspace", width = 80 }, function(_, idx)
		if not idx or not workspaces[idx] then
			return
		end
		local ws = workspaces[idx]
		local ws_name = ws.name

		-- Deep-copy agents so we can modify freely
		local selected_agents = {}
		for _, a in ipairs(ws.agents or {}) do
			table.insert(selected_agents, { name = a.name, role = a.role })
		end

		local function edit_menu()
			local menu = {}
			for _, entry in ipairs(selected_agents) do
				local role_hint = entry.role and ("  — " .. entry.role:sub(1, 40)) or ""
				table.insert(menu, "  ✓ " .. entry.name .. role_hint)
			end
			table.insert(menu, "Add existing agent")
			table.insert(menu, "Create new agent")
			table.insert(menu, "Done — save workspace")

			ui.select(menu, {
				prompt = string.format("Edit workspace '%s'", ws_name),
				width = 80,
			}, function(choice, choice_idx)
				if not choice then
					return
				end

				if choice == "Done — save workspace" then
					local ws_def = { name = ws_name, agents = selected_agents }
					workspace_mod.workspace_save(ws_def, cwd)
					return
				end

				if choice == "Add existing agent" then
					local agents = workspace_mod.agent_list(cwd)
					if #agents == 0 then
						vim.notify("nvim-agent: no agents defined — create one first", vim.log.levels.INFO)
						edit_menu()
						return
					end
					-- Filter out already-added agents
					local available = {}
					local added_names = {}
					for _, e in ipairs(selected_agents) do
						added_names[e.name] = true
					end
					for _, a in ipairs(agents) do
						if not added_names[a.name] then
							table.insert(available, a)
						end
					end
					if #available == 0 then
						vim.notify("nvim-agent: all agents already in workspace", vim.log.levels.INFO)
						edit_menu()
						return
					end
					local agent_options = {}
					for _, a in ipairs(available) do
						table.insert(agent_options, a.name)
					end
					ui.select(agent_options, { prompt = "Pick agent", width = 70 }, function(_, a_idx)
						if a_idx and available[a_idx] then
							local picked = available[a_idx].name
							ui.input({
								prompt = "",
								title = "Role for '" .. picked .. "' in this workspace (optional)",
							}, function(role)
								role = (role and role ~= "") and role or nil
								table.insert(selected_agents, { name = picked, role = role })
								edit_menu()
							end)
						else
							edit_menu()
						end
					end)
					return
				end

				if choice == "Create new agent" then
					M.agent_new_interactive(function(agent_name)
						if agent_name then
							ui.input({
								prompt = "",
								title = "Role for '" .. agent_name .. "' in this workspace (optional)",
							}, function(role)
								role = (role and role ~= "") and role or nil
								table.insert(selected_agents, { name = agent_name, role = role })
								edit_menu()
							end)
						else
							edit_menu()
						end
					end)
					return
				end

				-- Clicked an existing entry — offer to remove or edit role
				local entry_idx = choice_idx
				if entry_idx and entry_idx <= #selected_agents then
					local entry = selected_agents[entry_idx]
					ui.select({ "Remove from workspace", "Change role", "Keep" }, {
						prompt = "Agent '" .. entry.name .. "'",
						width = 50,
					}, function(action)
						if action == "Remove from workspace" then
							table.remove(selected_agents, entry_idx)
						elseif action == "Change role" then
							ui.input({
								prompt = "",
								title = "New role for '" .. entry.name .. "' (blank to clear)",
							}, function(role)
								selected_agents[entry_idx].role = (role and role ~= "") and role or nil
								edit_menu()
							end)
							return
						end
						edit_menu()
					end)
					return
				end
				edit_menu()
			end)
		end

		edit_menu()
	end)
end

--- Create a new workspace definition interactively.
--- Walks through: workspace name → add agents (each with a workspace-specific role) → save.
function M.workspace_new()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized — run 'NvimAgent workspace init' first", vim.log.levels.WARN)
		return
	end

	ui.input({ prompt = "", title = "New Workspace Name" }, function(ws_name)
		if not ws_name or ws_name == "" then
			return
		end

		-- Each entry: { name, role }
		local selected_agents = {}

		local function add_or_finish()
			local options = {}
			for _, entry in ipairs(selected_agents) do
				local role_hint = entry.role and ("  — " .. entry.role:sub(1, 40)) or ""
				table.insert(options, "  ✓ " .. entry.name .. role_hint)
			end
			table.insert(options, "Add existing agent")
			table.insert(options, "Create new agent")
			table.insert(options, "Done — save workspace")

			ui.select(options, {
				prompt = string.format("Workspace '%s' — add agents", ws_name),
				width = 80,
			}, function(choice, idx)
				if not choice then
					return
				end

				if choice == "Done — save workspace" then
					local ws_def = { name = ws_name, agents = selected_agents }
					workspace_mod.workspace_save(ws_def, cwd)
					M.workspace_launch(ws_def, cwd)
					return
				end

				if choice == "Add existing agent" then
					local agents = workspace_mod.agent_list(cwd)
					if #agents == 0 then
						vim.notify("nvim-agent: no agents defined — create one first", vim.log.levels.INFO)
						add_or_finish()
						return
					end
					-- Filter out already-added agents
					local available = {}
					local added_names = {}
					for _, e in ipairs(selected_agents) do
						added_names[e.name] = true
					end
					for _, a in ipairs(agents) do
						if not added_names[a.name] then
							table.insert(available, a)
						end
					end
					if #available == 0 then
						vim.notify("nvim-agent: all agents already in workspace", vim.log.levels.INFO)
						add_or_finish()
						return
					end
					local agent_options = {}
					for _, a in ipairs(available) do
						table.insert(agent_options, a.name)
					end
					ui.select(agent_options, { prompt = "Pick agent", width = 70 }, function(_, a_idx)
						if a_idx and available[a_idx] then
							local picked = available[a_idx].name
							ui.input({
								prompt = "",
								title = "Role for '" .. picked .. "' in this workspace (optional)",
							}, function(role)
								role = (role and role ~= "") and role or nil
								table.insert(selected_agents, { name = picked, role = role })
								add_or_finish()
							end)
						else
							add_or_finish()
						end
					end)
					return
				end
				if choice == "Create new agent" then
					M.agent_new_interactive(function(agent_name)
						if agent_name then
							ui.input({
								prompt = "",
								title = "Role for '" .. agent_name .. "' in this workspace (optional)",
							}, function(role)
								role = (role and role ~= "") and role or nil
								table.insert(selected_agents, { name = agent_name, role = role })
								add_or_finish()
							end)
						else
							add_or_finish()
						end
					end)
					return
				end

				-- Clicked an existing entry — offer to remove it
				if idx and idx <= #selected_agents then
					local entry = selected_agents[idx]
					ui.select({ "Remove from workspace", "Change role", "Keep" }, {
						prompt = "Agent '" .. entry.name .. "'",
						width = 50,
					}, function(action)
						if action == "Remove from workspace" then
							table.remove(selected_agents, idx)
						elseif action == "Change role" then
							ui.input({
								prompt = "",
								title = "New role for '" .. entry.name .. "' (blank to clear)",
							}, function(role)
								selected_agents[idx].role = (role and role ~= "") and role or nil
								add_or_finish()
							end)
							return
						end
						add_or_finish()
					end)
					return
				end
				add_or_finish()
			end)
		end

		add_or_finish()
	end)
end

--- List all agent definitions in the workspace definition directory.
function M.agent_list_ui()
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	local agents = workspace_mod.agent_list(cwd)
	if #agents == 0 then
		vim.notify("nvim-agent: no agents defined in workspace", vim.log.levels.INFO)
		return
	end
	local lines = {}
	for _, a in ipairs(agents) do
		table.insert(lines, "  " .. a.name)
	end
	vim.notify("nvim-agent agents:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Pick an agent from the workspace definition directory and delete it.
--- Also closes any active session running under that agent name.
function M.agent_remove()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	local session_mod = require("nvim-agent.session")
	local agents = workspace_mod.agent_list(cwd)
	if #agents == 0 then
		vim.notify("nvim-agent: no agents defined in workspace", vim.log.levels.INFO)
		return
	end
	local options = {}
	for _, a in ipairs(agents) do
		table.insert(options, a.name)
	end
	ui.select(options, { prompt = "Remove agent", width = 70 }, function(_, idx)
		if idx and agents[idx] then
			local name = agents[idx].name
			-- Close the running session for this agent (if any) so the name can be reused.
			local sess = session_mod.get_by_name(name)
			if sess then
				session_mod.close(sess.id)
			end
			workspace_mod.agent_delete(name, cwd)
		end
	end)
end

--- Interactively create a new agent definition in the workspace definition directory.
--- Prompts for a name, shows a flavor/checkpoint picker (global flavors + existing agents
--- as templates), then creates a session and opens a terminal buffer.
--- @param callback function|nil  Called with the agent name on success, nil on cancel.
function M.agent_new_interactive(callback)
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized — run 'NvimAgent workspace init' first", vim.log.levels.WARN)
		if callback then
			callback(nil)
		end
		return
	end

	ui.input({ prompt = "", title = "Agent Name" }, function(agent_name)
		if not agent_name or agent_name == "" then
			if callback then
				callback(nil)
			end
			return
		end

		if not workspace_mod.agent_create(agent_name, cwd) then
			if callback then
				callback(nil)
			end
			return
		end

		pick_flavor_for_ws_agent(agent_name, cwd, function(sel)
			local session_mod = require("nvim-agent.session")
			workspace_mod.init_runtime(cwd)

			local flavor_name = (sel.type == "global" and sel.flavor) or agent_name
			local checkpoint_name = (sel.type == "global") and sel.checkpoint or nil
			local sess, err = session_mod.create(flavor_name, checkpoint_name, agent_name)
			if not sess then
				vim.notify("nvim-agent: failed to create session: " .. (err or "?"), vim.log.levels.ERROR)
				if callback then
					callback(agent_name)
				end
				return
			end

			apply_ws_flavor(agent_name, sess.active_dir, sel, cwd)

			vim.notify(string.format("nvim-agent: agent '%s' created and launched", agent_name), vim.log.levels.INFO)
			vim.defer_fn(function()
				require("nvim-agent.terminal").open(sess.id)
			end, 300)

			if callback then
				callback(agent_name)
			end
		end)
	end)
end

--- Get the active_dir for the current session, or nil if no session.
local function current_active_dir()
	local sess = require("nvim-agent.session").get_current()
	return sess and sess.active_dir
end

--- Spawn a new workspace agent non-interactively (called from MCP RPC).
--- Creates the agent definition, writes context files, creates a session,
--- and opens the terminal buffer.
--- @param agent_name string
--- @param system_prompt string
--- @param role string
--- @param user_notes string
--- @return table  { success: boolean, error?: string }
function M.spawn_agent_noninteractive(agent_name, system_prompt, role, user_notes)
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	local session_mod = require("nvim-agent.session")
	local flavor_mod = require("nvim-agent.flavor")

	if not workspace_mod.has_workspace(cwd) then
		return { success = false, error = "no workspace initialized" }
	end

	-- Check if session with this name already exists
	if session_mod.get_by_name(agent_name) then
		return { success = false, error = "agent '" .. agent_name .. "' already exists as an active session" }
	end

	-- Create agent definition directory
	if not workspace_mod.agent_create(agent_name, cwd) then
		return { success = false, error = "failed to create agent definition for '" .. agent_name .. "'" }
	end

	-- Write context files to the agent definition directory
	local def_dir = workspace_mod.agent_content_dir(agent_name, cwd)
	if not def_dir then
		return { success = false, error = "failed to get agent content dir" }
	end

	local function write_file(path, content)
		local f = io.open(path, "w")
		if f then
			f:write(content)
			f:close()
		end
	end

	if system_prompt and system_prompt ~= "" then
		write_file(def_dir .. "/system_prompt.md", system_prompt)
	end
	if role and role ~= "" then
		write_file(def_dir .. "/role.md", role)
	end
	if user_notes and user_notes ~= "" then
		write_file(def_dir .. "/user_notes.md", user_notes)
	end

	-- Create backing flavor if needed
	if not flavor_mod.list_contains(agent_name) then
		flavor_mod.create(agent_name)
	end

	-- Create session
	workspace_mod.init_runtime(cwd)
	local sess, err = session_mod.create(agent_name, nil, agent_name)
	if not sess then
		return { success = false, error = "failed to create session: " .. (err or "?") }
	end

	-- Load agent definition content into session active_dir
	workspace_mod.agent_load_content(agent_name, sess.active_dir, cwd)
	flavor_mod.write_meta(agent_name, nil, sess.active_dir)

	-- Write initial status file for peer discovery
	local status_dir = workspace_mod.runtime_dir(cwd) .. "/status"
	vim.fn.mkdir(status_dir, "p")
	local sf = io.open(status_dir .. "/" .. agent_name .. ".json", "w")
	if sf then
		sf:write(vim.json.encode({
			agent = agent_name,
			role = (role and role ~= "") and role or nil,
			current_task = "spawned — awaiting instructions",
			updated_at = os.date("%Y-%m-%dT%H:%M:%SZ"),
		}))
		sf:close()
	end

	-- Open terminal buffer (deferred to avoid RPC blocking)
	vim.defer_fn(function()
		require("nvim-agent.terminal").open(sess.id)
	end, 300)

	vim.notify(string.format("nvim-agent: agent '%s' spawned", agent_name), vim.log.levels.INFO)
	return { success = true }
end

--- Persists any edits made to system_prompt, user_notes, persistent_dirs, role, etc.
function M.agent_save_current()
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized — run 'NvimAgent workspace init' first", vim.log.levels.WARN)
		return
	end

	local sess = require("nvim-agent.session").get_current()
	if not sess then
		vim.notify("nvim-agent: no active session to save", vim.log.levels.WARN)
		return
	end

	local dir = workspace_mod.agent_content_dir(sess.name, cwd)
	workspace_mod.agent_save_content(sess.name, sess.active_dir, cwd)
	vim.notify(string.format("nvim-agent: agent '%s' saved to %s/", sess.name, dir or "?"), vim.log.levels.INFO)
end

------------------------------------------------------------------------
-- Agent template management UI
------------------------------------------------------------------------

--- List all available agent templates.
function M.template_list_ui()
	local workspace_mod = require("nvim-agent.workspace")
	local templates = workspace_mod.template_list()
	if #templates == 0 then
		vim.notify("nvim-agent: no agent templates defined", vim.log.levels.INFO)
		return
	end
	local lines = {}
	for _, t in ipairs(templates) do
		table.insert(lines, "  " .. t)
	end
	vim.notify("nvim-agent templates:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Create a new template from an existing workspace agent's definition directory.
function M.template_create_ui()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	-- Offer to create from an existing agent or from scratch
	local agents = workspace_mod.agent_list(cwd)
	if #agents == 0 then
		vim.notify("nvim-agent: no agents to create template from", vim.log.levels.INFO)
		return
	end

	local options = {}
	for _, a in ipairs(agents) do
		table.insert(options, a.name)
	end

	ui.select(options, { prompt = "Create template from agent", width = 70 }, function(_, idx)
		if not idx or not agents[idx] then
			return
		end
		local agent_name = agents[idx].name
		local source_dir = workspace_mod.agent_content_dir(agent_name, cwd)
		if not source_dir then
			return
		end

		ui.input({ prompt = "", title = "Template name (default: " .. agent_name .. ")" }, function(name)
			name = (name and name ~= "") and name or agent_name
			workspace_mod.template_create(name, source_dir)
		end)
	end)
end

--- Pick and delete an agent template.
function M.template_remove_ui()
	local ui = require("nvim-agent.ui")
	local workspace_mod = require("nvim-agent.workspace")
	local templates = workspace_mod.template_list()
	if #templates == 0 then
		vim.notify("nvim-agent: no agent templates defined", vim.log.levels.INFO)
		return
	end
	ui.select(templates, { prompt = "Remove template", width = 70 }, function(choice)
		if choice then
			workspace_mod.template_delete(choice, vim.fn.getcwd())
		end
	end)
end

--- Pick a template and link it to an existing workspace agent.
function M.agent_set_template_ui()
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	local agents = workspace_mod.agent_list(cwd)
	if #agents == 0 then
		vim.notify("nvim-agent: no agents defined", vim.log.levels.INFO)
		return
	end

	local templates = workspace_mod.template_list()
	if #templates == 0 then
		vim.notify("nvim-agent: no templates available — create one first", vim.log.levels.INFO)
		return
	end

	local agent_options = {}
	for _, a in ipairs(agents) do
		local tmpl = workspace_mod.agent_get_template(a.name, cwd)
		local hint = tmpl and ("  [template: " .. tmpl .. "]") or ""
		table.insert(agent_options, a.name .. hint)
	end

	ui.select(agent_options, { prompt = "Set template for agent", width = 80 }, function(_, idx)
		if not idx or not agents[idx] then
			return
		end
		local agent_name = agents[idx].name

		-- Add "None" option to unlink
		local tmpl_options = { "(none — remove template link)" }
		for _, t in ipairs(templates) do
			table.insert(tmpl_options, t)
		end

		ui.select(tmpl_options, { prompt = "Template for '" .. agent_name .. "'", width = 70 }, function(choice, tidx)
			if not choice then
				return
			end
			if tidx == 1 then
				-- Remove template link
				workspace_mod.agent_set_template(agent_name, nil, cwd)
				vim.notify("nvim-agent: template unlinked from '" .. agent_name .. "'", vim.log.levels.INFO)
			else
				local tmpl_name = templates[tidx - 1]
				workspace_mod.agent_set_template(agent_name, tmpl_name, cwd)
				vim.notify(
					string.format("nvim-agent: agent '%s' linked to template '%s'", agent_name, tmpl_name),
					vim.log.levels.INFO
				)
			end
		end)
	end)
end

--- Open role.md for the given session's active_dir in an editor split.
--- The role describes this agent's expertise and goals so peers know when to delegate to it.
--- @param active_dir string|nil  Defaults to current session
function M.edit_role(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	vim.cmd("split " .. vim.fn.fnameescape(active_dir .. "/role.md"))
end

--- Open a context file for a workspace agent directly from the definition directory.
--- Useful for editing an agent's behavior without launching it.
--- @param filename string  e.g. "system_prompt.md", "user_notes.md", "role.md"
function M.edit_agent_file(filename)
	local ui = require("nvim-agent.ui")
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized", vim.log.levels.WARN)
		return
	end

	local agents = workspace_mod.agent_list(cwd)
	if #agents == 0 then
		vim.notify("nvim-agent: no agents defined in workspace", vim.log.levels.WARN)
		return
	end

	local names = {}
	for _, a in ipairs(agents) do
		table.insert(names, a.name)
	end

	ui.select(names, { prompt = "Edit " .. filename .. " for agent", width = 70 }, function(name)
		if not name then
			return
		end
		local dir = workspace_mod.agent_content_dir(name, cwd)
		if not dir then
			return
		end
		vim.fn.mkdir(dir, "p")
		vim.cmd("split " .. vim.fn.fnameescape(dir .. "/" .. filename))
	end)
end

--- Show a session picker when there are multiple active sessions.
--- With 0 sessions: calls callback(nil).
--- With 1 session: calls callback immediately (no UI shown).
--- With 2+ sessions: shows a picker so the user chooses explicitly.
--- @param prompt string
--- @param callback function(sess: table|nil)
function M.pick_session(prompt, callback)
	local session_mod = require("nvim-agent.session")
	local sessions = session_mod.list()
	if #sessions == 0 then
		callback(nil)
		return
	end
	if #sessions == 1 then
		callback(sessions[1])
		return
	end
	local ui = require("nvim-agent.ui")
	local options = {}
	for _, sess in ipairs(sessions) do
		local cp = sess.checkpoint and ("@ " .. sess.checkpoint) or "@ base"
		local marker = (sess.id == session_mod.current_id) and " *" or ""
		table.insert(options, string.format("%s: %s %s%s", sess.name, sess.flavor, cp, marker))
	end
	ui.select(options, { prompt = prompt, width = 70 }, function(choice)
		if not choice then
			return
		end
		local sname = choice:match("^([^:]+):")
		if sname then
			sname = sname:match("^%s*(.-)%s*$")
			callback(session_mod.get_by_name(sname))
		end
	end)
end

--- Graceful quit: confirm if agents are running, save workspace state, then quit.
function M.graceful_quit()
	local ui = require("nvim-agent.ui")
	local session_mod = require("nvim-agent.session")
	local sessions = session_mod.list()

	local running = {}
	for _, sess in ipairs(sessions) do
		if sess.jobid then
			table.insert(running, sess.name)
		end
	end

	local function do_quit()
		-- Save workspace state for all sessions before exit.
		local cwd = vim.fn.getcwd()
		local workspace_mod = require("nvim-agent.workspace")
		if workspace_mod.has_workspace(cwd) then
			for _, sess in ipairs(sessions) do
				pcall(workspace_mod.agent_save_content, sess.name, sess.active_dir, cwd)
			end
			vim.notify("nvim-agent: workspace state saved", vim.log.levels.INFO)
		end
		vim.cmd("qa!")
	end

	if #running == 0 then
		do_quit()
		return
	end

	ui.select({ "Quit and save workspace state", "Cancel" }, {
		prompt = string.format("%d agent(s) still running: %s", #running, table.concat(running, ", ")),
		width = 70,
	}, function(choice)
		if choice == "Quit and save workspace state" then
			do_quit()
		end
	end)
end

--- Open a scratch buffer showing aggregated content from one or more history files.
--- @param title string  Buffer name shown in the status line
--- @param files table   List of { name=string, path=string } entries to aggregate
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
		vim.notify("nvim-agent: no history files found", vim.log.levels.INFO)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, title)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end

--- View the work history for a single agent (picker when name is nil).
--- History file: <cwd>/.nvim-agent/history/<name>.md
--- @param name string|nil  Agent name; shows a picker if nil
function M.history_view_agent(name)
	local cwd = vim.fn.getcwd()
	local history_dir = cwd .. "/.nvim-agent/history"

	if name then
		local path = history_dir .. "/" .. name .. ".md"
		if vim.fn.filereadable(path) == 0 then
			vim.notify("nvim-agent: no history for agent '" .. name .. "'", vim.log.levels.INFO)
			return
		end
		open_history_scratch("Agent History: " .. name, { { name = name, path = path } })
		return
	end

	-- Collect candidates: live session names + history files on disk
	local seen = {}
	local candidates = {}

	local session_mod = require("nvim-agent.session")
	for _, sess in ipairs(session_mod.list()) do
		if not seen[sess.name] then
			seen[sess.name] = true
			table.insert(candidates, sess.name)
		end
	end

	local glob_result = vim.fn.glob(history_dir .. "/*.md", false, true)
	for _, p in ipairs(glob_result) do
		local n = vim.fn.fnamemodify(p, ":t:r")
		if not seen[n] then
			seen[n] = true
			table.insert(candidates, n)
		end
	end

	if #candidates == 0 then
		vim.notify("nvim-agent: no agent history found", vim.log.levels.INFO)
		return
	end
	if #candidates == 1 then
		M.history_view_agent(candidates[1])
		return
	end

	local ui = require("nvim-agent.ui")
	ui.select(candidates, { prompt = "View history for agent", width = 70 }, function(choice)
		if choice then
			M.history_view_agent(choice)
		end
	end)
end

--- View aggregated history for all agents in the current workspace definition.
function M.history_view_workspace()
	local cwd = vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")
	if not workspace_mod.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized", vim.log.levels.WARN)
		return
	end
	local agents = workspace_mod.agent_list(cwd)
	if #agents == 0 then
		vim.notify("nvim-agent: no agents defined in workspace", vim.log.levels.INFO)
		return
	end
	local history_dir = cwd .. "/.nvim-agent/history"
	local files = {}
	for _, a in ipairs(agents) do
		table.insert(files, { name = a.name, path = history_dir .. "/" .. a.name .. ".md" })
	end
	open_history_scratch("Workspace History", files)
end

--- View aggregated history for all agents that have history files in the project.
function M.history_view_project()
	local cwd = vim.fn.getcwd()
	local history_dir = cwd .. "/.nvim-agent/history"
	local paths = vim.fn.glob(history_dir .. "/*.md", false, true)
	if #paths == 0 then
		vim.notify("nvim-agent: no history files found in project", vim.log.levels.INFO)
		return
	end
	local files = {}
	for _, p in ipairs(paths) do
		local n = vim.fn.fnamemodify(p, ":t:r")
		table.insert(files, { name = n, path = p })
	end
	open_history_scratch("Project History", files)
end

function M.adapter_setup()
	local adapter_mod = require("nvim-agent.adapter")
	local adapter = adapter_mod.get_active()
	if not adapter then
		vim.notify("nvim-agent: no adapter configured", vim.log.levels.ERROR)
		return
	end
	adapter:setup()
end

-- Terminal (operate on current session)
function M.open()
	if not require("nvim-agent.session").get_current() then
		M.ensure_active_flavor()
		return
	end
	require("nvim-agent.terminal").open()
end

function M.close()
	require("nvim-agent.terminal").close()
end

function M.toggle()
	if not require("nvim-agent.session").get_current() then
		M.ensure_active_flavor()
		return
	end
	require("nvim-agent.terminal").toggle()
end

-- Context
function M.refresh_context()
	local sess = require("nvim-agent.session").get_current()
	if sess then
		require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)
		vim.notify("nvim-agent: context refreshed", vim.log.levels.INFO)
	end
end

-- System prompt (session-aware, optional active_dir for multi-session callers)
function M.edit_system_prompt(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local path = active_dir .. "/" .. config.get().context_files.system_prompt
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.view_system_prompt(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local ui = require("nvim-agent.ui")
	local path = active_dir .. "/" .. config.get().context_files.system_prompt
	ui.view_file(path, {
		title = "System Prompt (Read-Only)",
		filetype = "markdown",
		on_edit = function()
			M.edit_system_prompt(active_dir)
		end,
	})
end

-- User notes (session-aware, optional active_dir for multi-session callers)
function M.edit_user_notes(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local path = active_dir .. "/" .. config.get().context_files.user_notes
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.view_user_notes(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local ui = require("nvim-agent.ui")
	local path = active_dir .. "/" .. config.get().context_files.user_notes
	ui.view_file(path, {
		title = "User Notes (Read-Only)",
		filetype = "markdown",
		on_edit = function()
			M.edit_user_notes(active_dir)
		end,
	})
end

-- Persistent dirs (session-aware, optional active_dir for multi-session callers)
function M.edit_persistent_dirs(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local path = active_dir .. "/" .. config.get().context_files.persistent_dirs
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.view_persistent_dirs(active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local ui = require("nvim-agent.ui")
	local path = active_dir .. "/" .. config.get().context_files.persistent_dirs
	ui.view_file(path, {
		title = "Persistent Dirs (Read-Only)",
		filetype = "json",
		on_edit = function()
			M.edit_persistent_dirs(active_dir)
		end,
	})
end

function M.add_persistent_dir(tag, path, description, active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local dirs_path = active_dir .. "/" .. config.get().context_files.persistent_dirs
	local dirs_mod = require("nvim-agent.context.persistent_dirs")
	local entries = dirs_mod.load(dirs_path)
	for i, entry in ipairs(entries) do
		if entry.tag == tag then
			entries[i] = { tag = tag, path = path, description = description }
			dirs_mod.save(entries, dirs_path)
			vim.notify("nvim-agent: added directory '" .. tag .. "'", vim.log.levels.INFO)
			return
		end
	end
	table.insert(entries, { tag = tag, path = path, description = description })
	dirs_mod.save(entries, dirs_path)
	vim.notify("nvim-agent: added directory '" .. tag .. "'", vim.log.levels.INFO)
end

function M.remove_persistent_dir(tag, active_dir)
	active_dir = active_dir or current_active_dir()
	if not active_dir then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local dirs_path = active_dir .. "/" .. config.get().context_files.persistent_dirs
	local dirs_mod = require("nvim-agent.context.persistent_dirs")
	local entries = dirs_mod.load(dirs_path)
	for i, entry in ipairs(entries) do
		if entry.tag == tag then
			table.remove(entries, i)
			dirs_mod.save(entries, dirs_path)
			vim.notify("nvim-agent: removed directory '" .. tag .. "'", vim.log.levels.INFO)
			return
		end
	end
	vim.notify("nvim-agent: directory '" .. tag .. "' not found", vim.log.levels.WARN)
end

-- Flavors (session-aware: all mutations target current session's active_dir)
function M.flavor_create(name)
	require("nvim-agent.flavor").create(name, current_active_dir())
	vim.notify("nvim-agent: flavor '" .. name .. "' created", vim.log.levels.INFO)
end

function M.flavor_load(name, active_dir)
	active_dir = active_dir or current_active_dir()
	require("nvim-agent.flavor").load(name, nil, active_dir)
	-- Update the session label for whichever session owns this active_dir
	local session_mod = require("nvim-agent.session")
	for _, sess in ipairs(session_mod.list()) do
		if sess.active_dir == active_dir then
			sess.flavor = name
			sess.checkpoint = nil
			break
		end
	end
	vim.notify("nvim-agent: flavor '" .. name .. "' loaded", vim.log.levels.INFO)
end

function M.flavor_save(name, active_dir)
	active_dir = active_dir or current_active_dir()
	local flavor = require("nvim-agent.flavor")
	local target = name or flavor.current(active_dir)
	if not target then
		vim.notify("nvim-agent: no active flavor to save to (specify a name)", vim.log.levels.ERROR)
		return
	end
	flavor.save(target, active_dir)
	vim.notify("nvim-agent: saved to flavor '" .. target .. "'", vim.log.levels.INFO)
end

function M.flavor_list()
	local flavors = require("nvim-agent.flavor").list()
	if #flavors == 0 then
		vim.notify("nvim-agent: no flavors found", vim.log.levels.INFO)
		return
	end
	local act = current_active_dir()
	local current = act and require("nvim-agent.flavor").current(act)
	local lines = {}
	for _, f in ipairs(flavors) do
		local marker = (f == current) and " *" or ""
		table.insert(lines, "  " .. f .. marker)
	end
	vim.notify("nvim-agent flavors:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.flavor_delete(name)
	local flavor = require("nvim-agent.flavor")
	local success = flavor.delete(name)
	if not success then
		return
	end

	vim.notify("nvim-agent: flavor '" .. name .. "' deleted", vim.log.levels.INFO)

	-- Check if any active session is using this flavor; if so, prompt to reload for each
	local session_mod = require("nvim-agent.session")
	local affected = {}
	for _, sess in ipairs(session_mod.list()) do
		if sess.flavor == name then
			table.insert(affected, sess)
		end
	end
	if #affected > 0 then
		vim.schedule(function()
			vim.notify(
				"nvim-agent: deleted flavor '"
					.. name
					.. "' was in use. Select a replacement flavor for each affected session.",
				vim.log.levels.WARN
			)
			-- For each affected session, show a flavor picker that loads into that session's active_dir
			local function reload_next(i)
				if i > #affected then
					return
				end
				local sess = affected[i]
				local ui = require("nvim-agent.ui")
				local flavor_mod = require("nvim-agent.flavor")
				local flavors = flavor_mod.list()
				if #flavors == 0 then
					vim.notify("nvim-agent: no flavors available", vim.log.levels.ERROR)
					return
				end
				ui.select(flavors, {
					prompt = "Select replacement flavor for session '" .. sess.name .. "'",
					width = 70,
				}, function(choice)
					if choice then
						M.select_checkpoint_replacement(choice, sess, function()
							reload_next(i + 1)
						end)
					end
				end)
			end
			reload_next(1)
		end)
	end
end

--- Show checkpoint picker for a replacement flavor load into a specific session.
--- Calls callback() when done (or on cancel).
--- @param flavor_name string
--- @param sess table  Session object
--- @param callback function
function M.select_checkpoint_replacement(flavor_name, sess, callback)
	local ui = require("nvim-agent.ui")
	local checkpoints = require("nvim-agent.flavor.checkpoint").list(flavor_name)
	local options = { "base (default)" }
	for _, cp in ipairs(checkpoints) do
		table.insert(options, cp)
	end
	ui.select(options, {
		prompt = "Select checkpoint for '" .. flavor_name .. "' (session: " .. sess.name .. ")",
		width = 70,
	}, function(choice)
		if not choice then
			-- User cancelled checkpoint picker; skip this session
			if callback then
				callback()
			end
			return
		end
		local cp = (choice ~= "base (default)") and choice or nil
		if cp then
			require("nvim-agent.flavor.checkpoint").load(flavor_name, cp, sess.active_dir)
		else
			require("nvim-agent.flavor").load(flavor_name, nil, sess.active_dir)
		end
		sess.flavor = flavor_name
		sess.checkpoint = cp
		vim.notify(
			"nvim-agent: session '" .. sess.name .. "' reloaded with flavor '" .. flavor_name .. "'",
			vim.log.levels.INFO
		)
		if callback then
			callback()
		end
	end)
end

function M.flavor_rename(old_name, new_name)
	require("nvim-agent.flavor").rename(old_name, new_name)
	vim.notify("nvim-agent: flavor '" .. old_name .. "' renamed to '" .. new_name .. "'", vim.log.levels.INFO)
end

-- Checkpoints (session-aware)
function M.checkpoint_load(name, active_dir)
	active_dir = active_dir or current_active_dir()
	local current_flavor = require("nvim-agent.flavor").current(active_dir)
	if not current_flavor then
		vim.notify("nvim-agent: no active flavor (load a flavor first)", vim.log.levels.ERROR)
		return
	end
	require("nvim-agent.flavor.checkpoint").load(current_flavor, name, active_dir)
	local session_mod = require("nvim-agent.session")
	for _, sess in ipairs(session_mod.list()) do
		if sess.active_dir == active_dir then
			sess.checkpoint = name
			break
		end
	end
	vim.notify("nvim-agent: checkpoint '" .. name .. "' loaded", vim.log.levels.INFO)
end

function M.checkpoint_list()
	local active_dir = current_active_dir()
	local current_flavor = require("nvim-agent.flavor").current(active_dir)
	if not current_flavor then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	local checkpoints = require("nvim-agent.flavor.checkpoint").list(current_flavor)
	if #checkpoints == 0 then
		vim.notify("nvim-agent: no checkpoints for flavor '" .. current_flavor .. "'", vim.log.levels.INFO)
		return
	end
	local lines = {}
	for _, cp in ipairs(checkpoints) do
		table.insert(lines, "  " .. cp)
	end
	vim.notify("nvim-agent checkpoints (" .. current_flavor .. "):\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.checkpoint_delete(name)
	local active_dir = current_active_dir()
	local current_flavor = require("nvim-agent.flavor").current(active_dir)
	if not current_flavor then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	require("nvim-agent.flavor.checkpoint").delete(current_flavor, name)
	vim.notify("nvim-agent: checkpoint '" .. name .. "' deleted", vim.log.levels.INFO)
end

function M.checkpoint_sync()
	local active_dir = current_active_dir()
	local current_flavor = require("nvim-agent.flavor").current(active_dir)
	local current_checkpoint = require("nvim-agent.flavor").current_checkpoint(active_dir)
	if not current_flavor then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	if not current_checkpoint then
		vim.notify("nvim-agent: no active checkpoint (currently on base)", vim.log.levels.WARN)
		return
	end
	require("nvim-agent.flavor.checkpoint").sync_with_base(current_flavor, current_checkpoint, active_dir)
	vim.notify("nvim-agent: synced checkpoint '" .. current_checkpoint .. "' with base", vim.log.levels.INFO)
end

function M.checkpoint_save_to(target_checkpoint, active_dir)
	if not target_checkpoint or target_checkpoint == "" then
		vim.notify("nvim-agent: target checkpoint name required", vim.log.levels.ERROR)
		return
	end
	active_dir = active_dir or current_active_dir()
	local current_flavor = require("nvim-agent.flavor").current(active_dir)
	if not current_flavor then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	require("nvim-agent.flavor.checkpoint").save_to(current_flavor, target_checkpoint, active_dir)
	vim.notify("nvim-agent: saved to checkpoint '" .. target_checkpoint .. "'", vim.log.levels.INFO)
end

function M.save_to_base(active_dir)
	active_dir = active_dir or current_active_dir()
	local current_flavor = require("nvim-agent.flavor").current(active_dir)
	if not current_flavor then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	require("nvim-agent.flavor").save(current_flavor, active_dir)
	vim.notify("nvim-agent: saved to base flavor '" .. current_flavor .. "'", vim.log.levels.INFO)
end

-- Tmux capture (targets current/last-focused session's process_dir)
function M.tmux_add_capture(lines)
	local tmux = require("nvim-agent.context.tmux_capture")
	if not tmux.is_tmux() then
		vim.notify("nvim-agent: not running inside tmux", vim.log.levels.WARN)
		return
	end
	local sess = require("nvim-agent.session").get_current()
	if not sess then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local panes = tmux.list_panes()
	if #panes == 0 then
		vim.notify("nvim-agent: no other tmux panes found", vim.log.levels.INFO)
		return
	end
	local ui = require("nvim-agent.ui")
	local options = {}
	for _, p in ipairs(panes) do
		table.insert(options, p.display)
	end
	ui.select(options, { prompt = "Capture tmux pane", width = 70 }, function(choice, idx)
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
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	require("nvim-agent.context.tmux_capture").clear(sess.process_dir)
	vim.notify("nvim-agent: tmux captures cleared", vim.log.levels.INFO)
end

function M.tmux_view_captures()
	local sess = require("nvim-agent.session").get_current()
	if not sess then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	local cfg = config.get()
	local path = sess.process_dir .. "/" .. cfg.context_files.tmux_captures
	if vim.fn.filereadable(path) == 1 then
		vim.cmd("vsplit " .. vim.fn.fnameescape(path))
	else
		vim.notify("nvim-agent: no tmux captures found", vim.log.levels.INFO)
	end
end

--- Returns the active flavor/checkpoint string for the current session.
--- Format: "Agent-N: flavor @ checkpoint" or "Agent-N: flavor @ base"
--- Returns empty string if no session or flavor is active.
function M.statusline()
	local ok, session_mod = pcall(require, "nvim-agent.session")
	if not ok then
		return ""
	end
	local sess = session_mod.get_current()
	if not sess then
		return ""
	end

	local ok2, flavor = pcall(require, "nvim-agent.flavor")
	if not ok2 then
		return ""
	end

	local ok3, name = pcall(flavor.current, sess.active_dir)
	if not ok3 or not name then
		return ""
	end

	local cp = flavor.current_checkpoint(sess.active_dir) or "base"
	return string.format("Agent-%s: %s @ %s", sess.name, name, cp)
end

return M
