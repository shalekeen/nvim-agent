-- Agent definitions and templates.
--
-- An "agent" is a directory of files. The directory layout IS the schema —
-- there is no in-memory class, no agent registry table. Agents are stored at:
--
--   <cwd>/<def_dir>/agents/<name>/    project-scoped definitions (checked in)
--   ~/.nvim-agent/agent_templates/<name>/    global templates (reusable across projects)
--
-- Each agent dir contains a subset of AGENT_FILES (system_prompt.md is
-- always seeded; the rest are optional and only materialise when the user
-- edits them). An optional .agent_meta.json may declare a template parent:
-- { "template": "<name>" }. At session launch, template files are copied
-- first, then the agent-specific files are overlaid on top (agent wins).
--
-- Dependency: this module reaches into workspace.lua only for def_dir(cwd)
-- — the workspace owns the definition-directory path, agents live inside it.

local M = {}

local workspace = require("nvim-agent.workspace")

------------------------------------------------------------------------
-- Helpers (file JSON I/O — kept local to avoid leaking a generic util)
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
-- The canonical set of files an agent definition may contain.
-- Exported so other modules (adapters, tests) can iterate it without
-- duplicating the list.
------------------------------------------------------------------------

M.AGENT_FILES = {
	"system_prompt.md",
	"agent_prompt.md",
	"user_notes.md",
	"persistent_dirs.json",
	".flavor_meta.json",
	"role.md",
	"permissions.json",
}

------------------------------------------------------------------------
-- Agent definition dirs  (<def_dir>/agents/<name>/)
------------------------------------------------------------------------

--- Return the path to an agent's definition directory, or nil if no def_dir.
--- @param name string
--- @param cwd string|nil
--- @return string|nil
function M.content_dir(name, cwd)
	local dd = workspace.def_dir(cwd)
	if not dd then
		return nil
	end
	return dd .. "/agents/" .. name
end

--- List all agents defined in the definition directory.
--- @param cwd string|nil
--- @return table[]  { { name = string } }
function M.list(cwd)
	local dd = workspace.def_dir(cwd)
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
function M.get(name, cwd)
	local dir = M.content_dir(name, cwd)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		return nil
	end
	return { name = name }
end

--- Create an agent definition directory. Seeds an empty system_prompt.md so
--- the file is immediately editable; all other AGENT_FILES are created
--- lazily by the user (or by save_content from a live session).
--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.create(name, cwd)
	local dir = M.content_dir(name, cwd)
	if not dir then
		vim.notify("nvim-agent: no workspace initialized", vim.log.levels.WARN)
		return false
	end
	vim.fn.mkdir(dir, "p")
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

--- Delete an agent's definition directory AND remove it from every
--- workspace manifest that referenced it (workspace.lua owns that
--- manifest mutation; we delegate via require).
--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.delete(name, cwd)
	local dir = M.content_dir(name, cwd)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		vim.notify("nvim-agent: agent '" .. name .. "' not found", vim.log.levels.WARN)
		return false
	end
	vim.fn.delete(dir, "rf")
	workspace.remove_agent_from_workspaces(name, cwd)
	vim.notify("nvim-agent: agent '" .. name .. "' deleted", vim.log.levels.INFO)
	return true
end

--- Copy AGENT_FILES from a live session's active_dir into the agent's
--- definition dir. Call this to persist changes made during a session
--- back to the checked-in definition.
--- @param name string        Agent name
--- @param active_dir string  Session active_dir to read from
--- @param cwd string|nil
function M.save_content(name, active_dir, cwd)
	local dir = M.content_dir(name, cwd)
	if not dir then
		return
	end
	vim.fn.mkdir(dir, "p")
	for _, f in ipairs(M.AGENT_FILES) do
		local src = active_dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), dir .. "/" .. f)
		end
	end
end

--- Copy AGENT_FILES from the agent's definition dir into target_dir
--- (a session's active_dir). If the agent's .agent_meta.json declares a
--- template, the template is loaded first and then the agent's own files
--- are overlaid on top — agent overrides win on conflict.
--- @param name string        Agent name
--- @param target_dir string  Destination (session active_dir)
--- @param cwd string|nil
--- @return boolean           true if any agent files were copied
function M.load_content(name, target_dir, cwd)
	local dir = M.content_dir(name, cwd)
	if not dir or vim.fn.isdirectory(dir) == 0 then
		return false
	end

	-- 1. Template overlay (if linked)
	local meta = read_json(dir .. "/.agent_meta.json")
	if meta and meta.template then
		M.template_load(meta.template, target_dir)
	end

	-- 2. Agent-specific files on top (agent wins)
	local found_any = false
	for _, f in ipairs(M.AGENT_FILES) do
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
-- An agent references a template via .agent_meta.json: { "template": "<n>" }.
------------------------------------------------------------------------

--- Return the base directory holding all global agent templates.
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

--- List all available agent templates (sorted by name).
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

--- Create a new agent template by copying AGENT_FILES from a source dir
--- (typically an existing agent's def dir).
--- @param name string       Template name
--- @param source_dir string Directory to copy files from
--- @return boolean
function M.template_create(name, source_dir)
	local dir = M.template_dir(name)
	vim.fn.mkdir(dir, "p")
	for _, f in ipairs(M.AGENT_FILES) do
		local src = source_dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), dir .. "/" .. f)
		end
	end
	vim.notify("nvim-agent: template '" .. name .. "' created", vim.log.levels.INFO)
	return true
end

--- Delete an agent template.
--- Warns if any agents in the current workspace reference it (they will keep
--- working — their def dirs already hold a merged copy from prior launches).
--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.template_delete(name, cwd)
	local dir = M.template_dir(name)
	if vim.fn.isdirectory(dir) == 0 then
		vim.notify("nvim-agent: template '" .. name .. "' not found", vim.log.levels.WARN)
		return false
	end

	if workspace.has_workspace(cwd) then
		local linked = {}
		for _, a in ipairs(M.list(cwd)) do
			if M.get_template(a.name, cwd) == name then
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

--- Copy template files into a target directory. Does NOT overlay anything
--- on top — callers (typically load_content) handle layering.
--- @param name string       Template name
--- @param target_dir string Destination directory
--- @return boolean
function M.template_load(name, target_dir)
	local dir = M.template_dir(name)
	if vim.fn.isdirectory(dir) == 0 then
		return false
	end
	for _, f in ipairs(M.AGENT_FILES) do
		local src = dir .. "/" .. f
		if vim.fn.filereadable(src) == 1 then
			vim.fn.writefile(vim.fn.readfile(src), target_dir .. "/" .. f)
		end
	end
	return true
end

--- Link an agent to a template by writing/updating .agent_meta.json.
--- Passing template_name = nil clears the link.
--- @param agent_name string
--- @param template_name string|nil
--- @param cwd string|nil
function M.set_template(agent_name, template_name, cwd)
	local dir = M.content_dir(agent_name, cwd)
	if not dir then
		return
	end
	vim.fn.mkdir(dir, "p")
	local meta_path = dir .. "/.agent_meta.json"
	local meta = read_json(meta_path) or {}
	meta.template = template_name
	write_json(meta_path, meta)
end

--- Return the template name an agent is linked to, or nil.
--- @param agent_name string
--- @param cwd string|nil
--- @return string|nil
function M.get_template(agent_name, cwd)
	local dir = M.content_dir(agent_name, cwd)
	if not dir then
		return nil
	end
	local meta = read_json(dir .. "/.agent_meta.json")
	return meta and meta.template
end

return M
