-- Project-local agent and workspace management.
--
-- Two-layer directory structure:
--
--   <cwd>/.nvim-agent/             RUNTIME — gitignored, ephemeral state
--     config.json                  { workspace_def_dir = "<rel-path>" }
--     messages/                    agent-to-agent messages
--     status/                      peer discovery (*.json)
--     history/                     persistent work logs (*.md)
--
--   <cwd>/<def_dir>/               DEFINITIONS — checked into git, user-named
--     agents/<name>/               one directory per agent, containing:
--       system_prompt.md           agent system prompt
--       user_notes.md              persistent user notes
--       persistent_dirs.json       pinned code paths
--       .flavor_meta.json          flavor/checkpoint metadata
--       role.md                    agent role for peer discovery
--     workspaces/<name>.json       workspace: { name, agents: [{name, role}] }
--
-- Mode 1 (standalone): no .nvim-agent/ involved; uses ~/.nvim-agent/ globally.
-- Mode 2 (workspace):  both dirs used; agent defs are checked in, runtime is gitignored.
--
-- Roles are workspace-scoped: the same agent can have different roles in
-- different workspaces (or across projects).

local M = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function read_json(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	if not content or content == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, content)
	return (ok and type(data) == "table") and data or nil
end

--- Atomically write JSON to `path`: writes to <path>.tmp, then renames. A crash
--- mid-write therefore leaves the previous (valid) file intact rather than a
--- truncated/half-written one that read_json would silently treat as missing.
local function write_json(path, data)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		vim.notify("nvim-agent: failed to write " .. path, vim.log.levels.ERROR)
		return false
	end
	f:write(vim.json.encode(data))
	f:close()
	local ok, err = os.rename(tmp, path)
	if not ok then
		os.remove(tmp)
		vim.notify(
			"nvim-agent: failed to rename " .. tmp .. " → " .. path .. ": " .. tostring(err),
			vim.log.levels.ERROR
		)
		return false
	end
	return true
end

------------------------------------------------------------------------
-- Runtime dir  (<cwd>/.nvim-agent/ — gitignored)
------------------------------------------------------------------------

--- Return the runtime .nvim-agent/ directory path (NOT checked into git).
--- @param cwd string|nil
--- @return string
function M.runtime_dir(cwd)
	return (cwd or vim.fn.getcwd()) .. "/.nvim-agent"
end

--- Create the runtime directory structure (messages, status, history).
--- @param cwd string|nil
--- @return string  Runtime dir path
function M.init_runtime(cwd)
	local dir = M.runtime_dir(cwd)
	vim.fn.mkdir(dir .. "/messages", "p")
	vim.fn.mkdir(dir .. "/status", "p")
	vim.fn.mkdir(dir .. "/history", "p")
	return dir
end

------------------------------------------------------------------------
-- Config  (<cwd>/.nvim-agent/config.json)
------------------------------------------------------------------------

--- @param cwd string|nil
--- @return string
function M.config_path(cwd)
	return M.runtime_dir(cwd) .. "/config.json"
end

--- Read workspace config. Returns nil if not initialized.
--- @param cwd string|nil
--- @return table|nil  { workspace_def_dir = "..." }
function M.read_config(cwd)
	return read_json(M.config_path(cwd))
end

--- Write workspace config.
--- @param cwd string|nil
--- @param cfg table
function M.write_config(cwd, cfg)
	vim.fn.mkdir(M.runtime_dir(cwd), "p")
	write_json(M.config_path(cwd), cfg)
end

------------------------------------------------------------------------
-- Definition dir  (<cwd>/<workspace_def_dir>/ — checked into git)
------------------------------------------------------------------------

--- Return the absolute path to the definition directory, or nil if not configured.
--- @param cwd string|nil
--- @return string|nil
function M.def_dir(cwd)
	local cfg = M.read_config(cwd)
	if not cfg or not cfg.workspace_def_dir then
		return nil
	end
	return (cwd or vim.fn.getcwd()) .. "/" .. cfg.workspace_def_dir
end

--- Return true if a workspace has been initialized (config + def dir both exist).
--- @param cwd string|nil
--- @return boolean
function M.has_workspace(cwd)
	local dd = M.def_dir(cwd)
	return dd ~= nil and vim.fn.isdirectory(dd) == 1
end

--- Initialize a new workspace: create the definition directory + runtime dir,
--- write config.json pointing at the definition directory.
--- @param cwd string|nil
--- @param def_dir_name string  Relative name of the definitions directory (checked into git)
--- @return string  Absolute path to the definition directory
function M.init(cwd, def_dir_name)
	cwd = cwd or vim.fn.getcwd()
	local dd = cwd .. "/" .. def_dir_name
	vim.fn.mkdir(dd .. "/agents", "p")
	vim.fn.mkdir(dd .. "/workspaces", "p")
	M.init_runtime(cwd)
	M.write_config(cwd, { workspace_def_dir = def_dir_name })
	return dd
end

------------------------------------------------------------------------
-- Workspace ↔ agent crosswalk: removing an agent must scrub it from
-- every manifest that referenced it. Agent definition CRUD itself lives
-- in lua/nvim-agent/agent.lua; this function is the workspace-side
-- complement, called by agent.delete().
------------------------------------------------------------------------

--- Strip `agent_name` from every workspace manifest that lists it, then
--- re-save the touched manifests.
--- @param agent_name string
--- @param cwd string|nil
function M.remove_agent_from_workspaces(agent_name, cwd)
	local workspaces = M.workspace_list(cwd)
	for _, ws in ipairs(workspaces) do
		local filtered = {}
		local found = false
		for _, a in ipairs(ws.agents or {}) do
			if a.name == agent_name then
				found = true
			else
				table.insert(filtered, a)
			end
		end
		if found then
			ws.agents = filtered
			M.workspace_save(ws, cwd)
		end
	end
end

------------------------------------------------------------------------
-- Workspace definitions  (<def_dir>/workspaces/<name>.json)
-- Schema: { name, agents: [{ name, role }] }
------------------------------------------------------------------------

--- @param cwd string|nil
--- @return table[]
function M.workspace_list(cwd)
	local dd = M.def_dir(cwd)
	if not dd then
		return {}
	end
	local paths = vim.fn.glob(dd .. "/workspaces/*.json", false, true)
	local workspaces = {}
	for _, path in ipairs(paths) do
		local def = read_json(path)
		if def then
			table.insert(workspaces, def)
		end
	end
	table.sort(workspaces, function(a, b)
		return (a.name or "") < (b.name or "")
	end)
	return workspaces
end

--- @param name string
--- @param cwd string|nil
--- @return table|nil
function M.workspace_get(name, cwd)
	local dd = M.def_dir(cwd)
	if not dd then
		return nil
	end
	return read_json(dd .. "/workspaces/" .. name .. ".json")
end

--- Create or update a workspace definition.
--- @param def table  { name, agents: [{ name, role }] }
--- @param cwd string|nil
function M.workspace_save(def, cwd)
	local dd = M.def_dir(cwd)
	if not dd then
		vim.notify("nvim-agent: no workspace initialized — run workspace init first", vim.log.levels.WARN)
		return
	end
	local dir = dd .. "/workspaces"
	vim.fn.mkdir(dir, "p")
	if write_json(dir .. "/" .. def.name .. ".json", def) then
		vim.notify("nvim-agent: workspace '" .. def.name .. "' saved", vim.log.levels.INFO)
	end
end

--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.workspace_delete(name, cwd)
	local dd = M.def_dir(cwd)
	if not dd then
		return false
	end
	local path = dd .. "/workspaces/" .. name .. ".json"
	if vim.fn.filereadable(path) == 1 then
		vim.fn.delete(path)
		vim.notify("nvim-agent: workspace '" .. name .. "' deleted", vim.log.levels.INFO)
		return true
	end
	vim.notify("nvim-agent: workspace '" .. name .. "' not found", vim.log.levels.WARN)
	return false
end

------------------------------------------------------------------------
-- Snapshot: save all live sessions → agent defs + workspace definition
------------------------------------------------------------------------

--- Snapshot all open sessions into the definition directory as a named workspace.
--- Each session's active_dir is copied into <def_dir>/agents/<name>/.
--- @param workspace_name string
--- @param cwd string|nil
--- @return boolean
function M.save_current_as(workspace_name, cwd)
	cwd = cwd or vim.fn.getcwd()
	if not M.has_workspace(cwd) then
		vim.notify("nvim-agent: no workspace initialized — run workspace init first", vim.log.levels.WARN)
		return false
	end

	local sessions = require("nvim-agent.session").list()
	if #sessions == 0 then
		vim.notify("nvim-agent: no active sessions to save", vim.log.levels.WARN)
		return false
	end
	-- Lazy require to avoid a load-time cycle: agent.lua requires this
	-- module at the top, so we cannot require("agent") at file scope.
	local agent = require("nvim-agent.agent")
	local ws_agents = {}
	for _, sess in ipairs(sessions) do
		agent.save_content(sess.name, sess.active_dir, cwd)
		local role = nil
		local rf = io.open(sess.active_dir .. "/role.md", "r")
		if rf then
			local content = rf:read("*a")
			rf:close()
			if content and not content:match("^%s*$") then
				role = content:gsub("\n$", "")
			end
		end
		table.insert(ws_agents, { name = sess.name, role = role })
	end

	M.workspace_save({ name = workspace_name, agents = ws_agents }, cwd)

	local names = {}
	for _, a in ipairs(ws_agents) do
		table.insert(names, a.name)
	end
	vim.notify(
		string.format(
			"nvim-agent: workspace '%s' saved (%d agents: %s)",
			workspace_name,
			#ws_agents,
			table.concat(names, ", ")
		),
		vim.log.levels.INFO
	)
	return true
end

return M
