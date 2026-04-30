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
		vim.notify("nvim-agent: failed to rename " .. tmp .. " → " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
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
-- Agent definitions  (<def_dir>/agents/<name>/)
--
-- An agent IS its directory.  The directory contains all context files
-- needed to spawn it.  No separate JSON metadata file — the directory
-- name is the agent name.
--
-- Context files (all optional except system_prompt.md):
--   system_prompt.md     agent instructions
--   user_notes.md        persistent user-facing notes
--   persistent_dirs.json pinned code paths { tag, path, description }[]
--   .flavor_meta.json    flavor/checkpoint metadata
--   role.md              workspace role for peer discovery
------------------------------------------------------------------------

--- Return the path to an agent's definition directory, or nil if no def_dir.
--- @param name string
--- @param cwd string|nil
--- @return string|nil
function M.agent_content_dir(name, cwd)
	local dd = M.def_dir(cwd)
	if not dd then
		return nil
	end
	return dd .. "/agents/" .. name
end

--- List all agents defined in the definition directory.
--- @param cwd string|nil
--- @return table[]  { name }
function M.agent_list(cwd)
	local dd = M.def_dir(cwd)
	if not dd then
		return {}
	end
	local subdirs = vim.fn.glob(dd .. "/agents/*/", false, true)
	local agents = {}
	for _, path in ipairs(subdirs) do
		local name = path:match("/([^/]+)/$")
		if name then
			table.insert(agents, { name = name })
		end
	end
	table.sort(agents, function(a, b)
		return a.name < b.name
	end)
	return agents
end

--- Return { name } if the agent directory exists, nil otherwise.
--- @param name string
--- @param cwd string|nil
--- @return table|nil
function M.agent_get(name, cwd)
	local dir = M.agent_content_dir(name, cwd)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		return nil
	end
	return { name = name }
end

--- Create an agent definition directory (and optional seed files).
--- @param name string
--- @param cwd string|nil
function M.agent_create(name, cwd)
	local dir = M.agent_content_dir(name, cwd)
	if not dir then
		vim.notify("nvim-agent: no workspace initialized", vim.log.levels.WARN)
		return false
	end
	vim.fn.mkdir(dir, "p")
	-- Seed an empty system prompt so the file is immediately editable
	local sp = dir .. "/system_prompt.md"
	if vim.fn.filereadable(sp) == 0 then
		local f = io.open(sp, "w")
		if f then
			f:write("")
			f:close()
		end
	end
	return true
end

--- Delete an agent's definition directory and remove it from all workspace definitions.
--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.agent_delete(name, cwd)
	local dir = M.agent_content_dir(name, cwd)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		vim.notify("nvim-agent: agent '" .. name .. "' not found", vim.log.levels.WARN)
		return false
	end
	vim.fn.delete(dir, "rf")
	-- Remove agent from all workspace definitions that reference it
	M.remove_agent_from_workspaces(name, cwd)
	vim.notify("nvim-agent: agent '" .. name .. "' deleted", vim.log.levels.INFO)
	return true
end

--- Remove an agent from all workspace definitions that reference it.
--- Updates and re-saves any workspace JSON files that included the agent.
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

--- The standard set of context files managed per agent.
local AGENT_FILES = {
	"system_prompt.md",
	"user_notes.md",
	"persistent_dirs.json",
	".flavor_meta.json",
	"role.md",
	"permissions.json",
}

--- Copy context files from a live session's active_dir into the agent's definition dir.
--- Call this to persist changes made during a session back to the checked-in definition.
--- @param name string        Agent name
--- @param active_dir string  Session active_dir to read from
--- @param cwd string|nil
function M.agent_save_content(name, active_dir, cwd)
	local dir = M.agent_content_dir(name, cwd)
	if not dir then
		return
	end
	vim.fn.mkdir(dir, "p")
	for _, f in ipairs(AGENT_FILES) do
		local src = active_dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), dir .. "/" .. f)
		end
	end
end

--- Copy context files from the agent's definition dir into target_dir (session active_dir).
--- If the agent has a "template" field in its .agent_meta.json, the template is loaded
--- first, then the agent's own files are overlaid on top (agent overrides win).
--- Returns true if any files were found and copied.
--- @param name string        Agent name
--- @param target_dir string  Destination (session active_dir)
--- @param cwd string|nil
--- @return boolean
function M.agent_load_content(name, target_dir, cwd)
	local dir = M.agent_content_dir(name, cwd)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		return false
	end

	-- Check if this agent inherits from a global template
	local meta = read_json(dir .. "/.agent_meta.json")
	if meta and meta.template then
		M.template_load(meta.template, target_dir)
	end

	-- Overlay agent-specific files on top (agent overrides win)
	local found_any = false
	for _, f in ipairs(AGENT_FILES) do
		local src = dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), target_dir .. "/" .. f)
			found_any = true
		end
	end
	return found_any
end

------------------------------------------------------------------------
-- Agent templates  (~/.nvim-agent/agent_templates/<name>/)
--
-- Templates are global, reusable agent definitions shared across projects.
-- An agent references a template via .agent_meta.json: { "template": "<name>" }
-- When loading, template files are copied first, then agent-specific files
-- overlay on top — so the agent can override any template file.
------------------------------------------------------------------------

--- Return the base directory for all agent templates.
--- @return string
function M.template_base_dir()
	return require("nvim-agent.config").get().base_dir .. "/agent_templates"
end

--- Return the path to a specific template directory.
--- @param name string
--- @return string
function M.template_dir(name)
	return M.template_base_dir() .. "/" .. name
end

--- List all available agent templates.
--- @return string[]
function M.template_list()
	local base = M.template_base_dir()
	if vim.fn.isdirectory(base) == 0 then
		return {}
	end
	local entries = vim.fn.readdir(base)
	local templates = {}
	for _, entry in ipairs(entries) do
		if not entry:match("^%.") and vim.fn.isdirectory(base .. "/" .. entry) == 1 then
			table.insert(templates, entry)
		end
	end
	table.sort(templates)
	return templates
end

--- Create a new agent template from a source directory (e.g., an agent's def dir).
--- @param name string       Template name
--- @param source_dir string Directory to copy files from
--- @return boolean
function M.template_create(name, source_dir)
	local dir = M.template_dir(name)
	vim.fn.mkdir(dir, "p")
	for _, f in ipairs(AGENT_FILES) do
		local src = source_dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), dir .. "/" .. f)
		end
	end
	vim.notify("nvim-agent: template '" .. name .. "' created", vim.log.levels.INFO)
	return true
end

--- Delete an agent template.
--- Warns if any agents in the current workspace reference it.
--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.template_delete(name, cwd)
	local dir = M.template_dir(name)
	if vim.fn.isdirectory(dir) == 0 then
		vim.notify("nvim-agent: template '" .. name .. "' not found", vim.log.levels.WARN)
		return false
	end

	-- Check for linked agents in the current workspace
	if M.has_workspace(cwd) then
		local linked = {}
		for _, a in ipairs(M.agent_list(cwd)) do
			if M.agent_get_template(a.name, cwd) == name then
				table.insert(linked, a.name)
			end
		end
		if #linked > 0 then
			vim.notify(
				string.format(
					"nvim-agent: warning — %d agent(s) reference template '%s': %s\n"
						.. "Their def dirs already contain merged content from prior launches, so they will continue to work.",
					#linked,
					name,
					table.concat(linked, ", ")
				),
				vim.log.levels.WARN
			)
		end
	end

	vim.fn.delete(dir, "rf")
	vim.notify("nvim-agent: template '" .. name .. "' deleted", vim.log.levels.INFO)
	return true
end

--- Copy template files into a target directory.
--- @param name string       Template name
--- @param target_dir string Destination directory
--- @return boolean
function M.template_load(name, target_dir)
	local dir = M.template_dir(name)
	if vim.fn.isdirectory(dir) == 0 then
		return false
	end
	for _, f in ipairs(AGENT_FILES) do
		local src = dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), target_dir .. "/" .. f)
		end
	end
	return true
end

--- Link an agent to a template by writing .agent_meta.json.
--- @param agent_name string
--- @param template_name string
--- @param cwd string|nil
function M.agent_set_template(agent_name, template_name, cwd)
	local dir = M.agent_content_dir(agent_name, cwd)
	if not dir then
		return
	end
	vim.fn.mkdir(dir, "p")
	local meta_path = dir .. "/.agent_meta.json"
	local meta = read_json(meta_path) or {}
	meta.template = template_name
	write_json(meta_path, meta)
end

--- Get the template name an agent is linked to, or nil.
--- @param agent_name string
--- @param cwd string|nil
--- @return string|nil
function M.agent_get_template(agent_name, cwd)
	local dir = M.agent_content_dir(agent_name, cwd)
	if not dir then
		return nil
	end
	local meta = read_json(dir .. "/.agent_meta.json")
	return meta and meta.template
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

	local ws_agents = {}
	for _, sess in ipairs(sessions) do
		M.agent_save_content(sess.name, sess.active_dir, cwd)
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
