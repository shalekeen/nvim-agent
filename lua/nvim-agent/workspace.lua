-- Workspaces: which agents run together in a project.
--
--   <cwd>/.nvim-agent/                       gitignored, project-local
--     workspaces/<name>/workspace.json       manifest: { name, agents = [{ name, agent }] }
--     workspaces/ephemeral/workspace.json    the auto-created scratch workspace
--     instances/<instance_id>/               THIS Neovim's peer state
--       status/  messages/  history/  triggers/
--
-- A manifest entry pairs a SESSION name (unique within the workspace, what
-- peers address) with the global AGENT it is built from (agent.lua). The
-- same agent may appear twice under different session names.
--
-- Membership vs liveness: the manifest is membership. Whether a member's
-- CLI process is currently running is session state (session.lua), not
-- manifest state — a crashed or exited agent stays a member and can be
-- relaunched. Only add_entry / remove_entry change membership, and both
-- write the manifest immediately; there is no separate "save" step.
--
-- One workspace is live per Neovim instance (M.current). Manifests
-- themselves are project-level and may be loaded by several instances.

local M = {}

M.EPHEMERAL = "ephemeral"
M.MANIFEST_FILE = "workspace.json"

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

--- Atomically write JSON: write <path>.tmp then rename, so a crash mid-write
--- leaves the previous valid file rather than a truncated one.
local function write_json(path, data)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
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
-- Runtime dirs
------------------------------------------------------------------------

--- Project-level runtime root (gitignored). Holds workspaces/ and instances/.
--- @param cwd string|nil
--- @return string
function M.runtime_dir(cwd)
	return (cwd or vim.fn.getcwd()) .. "/.nvim-agent"
end

--- This Neovim instance's peer-state root. Handed to the agent CLI and MCP
--- server as $NVIM_AGENT_RUNTIME_DIR so two Neovims on the same project never
--- see each other's agents.
--- @param cwd string|nil
--- @return string
function M.instance_runtime_dir(cwd)
	return M.runtime_dir(cwd) .. "/instances/" .. require("nvim-agent.session").instance_id
end

--- Create this instance's peer-state subdirectories.
--- @param cwd string|nil
--- @return string  instance runtime dir
function M.init_runtime(cwd)
	local dir = M.instance_runtime_dir(cwd)
	for _, sub in ipairs({ "messages", "status", "history", "triggers" }) do
		vim.fn.mkdir(dir .. "/" .. sub, "p")
	end
	return dir
end

------------------------------------------------------------------------
-- Manifests
------------------------------------------------------------------------

--- @param cwd string|nil
--- @return string
function M.workspaces_dir(cwd)
	return M.runtime_dir(cwd) .. "/workspaces"
end

--- @param name string
--- @param cwd string|nil
--- @return string
function M.manifest_path(name, cwd)
	return M.workspaces_dir(cwd) .. "/" .. name .. "/" .. M.MANIFEST_FILE
end

--- True when the project has ever had a workspace (used by the startup flow
--- to decide between "first launch here" and "show the picker").
--- @param cwd string|nil
--- @return boolean
function M.any_exist(cwd)
	return #M.list(cwd) > 0
end

--- Validate a workspace name.
--- @param name any
--- @param allow_ephemeral boolean|nil
--- @return boolean, string|nil
function M.validate_name(name, allow_ephemeral)
	if type(name) ~= "string" or name == "" then
		return false, "workspace name is required"
	end
	if name:find("/", 1, true) or name:find("\\", 1, true) or name:match("^%.") then
		return false, "workspace name may not contain path separators or start with '.'"
	end
	if name == M.EPHEMERAL and not allow_ephemeral then
		return false, "'" .. M.EPHEMERAL .. "' is reserved for the ephemeral workspace"
	end
	return true
end

--- @param name string
--- @return table  { name = name, agents = {} }
function M.new_manifest(name)
	return { name = name, agents = {} }
end

--- Read a manifest, or nil if it does not exist / is unreadable.
--- @param name string
--- @param cwd string|nil
--- @return table|nil
function M.read(name, cwd)
	local m = read_json(M.manifest_path(name, cwd))
	if not m then
		return nil
	end
	m.name = name
	m.agents = m.agents or {}
	return m
end

--- @param name string
--- @param cwd string|nil
--- @return boolean
function M.exists(name, cwd)
	return vim.fn.filereadable(M.manifest_path(name, cwd)) == 1
end

--- Persist a manifest.
--- @param manifest table
--- @param cwd string|nil
--- @return boolean
function M.save(manifest, cwd)
	return write_json(M.manifest_path(manifest.name, cwd), {
		name = manifest.name,
		agents = manifest.agents or {},
	})
end

--- List all manifests in the project. The ephemeral workspace, when present,
--- is always first; the rest are sorted by name.
--- @param cwd string|nil
--- @return table[]  manifests, each with `ephemeral = boolean`
function M.list(cwd)
	local base = M.workspaces_dir(cwd)
	if vim.fn.isdirectory(base) ~= 1 then
		return {}
	end
	local out = {}
	for _, entry in ipairs(vim.fn.readdir(base)) do
		if not entry:match("^%.") then
			local m = M.read(entry, cwd)
			if m then
				m.ephemeral = (entry == M.EPHEMERAL)
				table.insert(out, m)
			end
		end
	end
	table.sort(out, function(a, b)
		if a.ephemeral ~= b.ephemeral then
			return a.ephemeral
		end
		return a.name < b.name
	end)
	return out
end

--- @param name string
--- @param cwd string|nil
--- @return boolean ok, string|nil err
function M.delete(name, cwd)
	local dir = M.workspaces_dir(cwd) .. "/" .. name
	if vim.fn.isdirectory(dir) ~= 1 then
		return false, "workspace '" .. name .. "' not found"
	end
	vim.fn.delete(dir, "rf")
	if M.current and M.current.name == name then
		M.current = nil
	end
	return true
end

--- Rename a workspace. Also used to promote the ephemeral workspace to a
--- named one. Updates M.current when it is the one being renamed.
--- @param old string
--- @param new string
--- @param cwd string|nil
--- @return boolean ok, string|nil err
function M.rename(old, new, cwd)
	local ok, err = M.validate_name(new)
	if not ok then
		return false, err
	end
	if not M.exists(old, cwd) then
		return false, "workspace '" .. old .. "' not found"
	end
	if M.exists(new, cwd) then
		return false, "workspace '" .. new .. "' already exists"
	end
	local base = M.workspaces_dir(cwd)
	if vim.fn.rename(base .. "/" .. old, base .. "/" .. new) ~= 0 then
		return false, "rename failed"
	end
	local m = M.read(new, cwd)
	if m then
		M.save(m, cwd)
	end
	if M.current and M.current.name == old then
		M.current.name = new
	end
	return true
end

------------------------------------------------------------------------
-- Membership
------------------------------------------------------------------------

--- Find a manifest entry by session name.
--- @param manifest table
--- @param session_name string
--- @return table|nil entry, integer|nil index
function M.find_entry(manifest, session_name)
	for i, e in ipairs(manifest.agents or {}) do
		if e.name == session_name then
			return e, i
		end
	end
	return nil
end

--- Add a member and persist. `entry.name` is the session name (defaults to
--- the agent name) and must be unique within the workspace; `entry.agent` is
--- the global agent it is built from and must exist.
--- @param manifest table
--- @param entry table  { agent = string, name = string|nil }
--- @param cwd string|nil
--- @return boolean ok, string|nil err
function M.add_entry(manifest, entry, cwd)
	local agent_mod = require("nvim-agent.agent")
	if not entry or not entry.agent then
		return false, "entry.agent is required"
	end
	if not agent_mod.exists(entry.agent) then
		return false, "agent '" .. entry.agent .. "' not found in the global library"
	end
	entry.name = (entry.name and entry.name ~= "") and entry.name or entry.agent
	if entry.name:find("/", 1, true) then
		return false, "session name may not contain '/'"
	end
	if M.find_entry(manifest, entry.name) then
		return false, "'" .. entry.name .. "' is already in workspace '" .. manifest.name .. "'"
	end
	manifest.agents = manifest.agents or {}
	table.insert(manifest.agents, { name = entry.name, agent = entry.agent })
	M.save(manifest, cwd)
	return true
end

--- Remove a member and persist. Also deletes the member's override files.
--- @param manifest table
--- @param session_name string
--- @param cwd string|nil
--- @return boolean ok, string|nil err
function M.remove_entry(manifest, session_name, cwd)
	local _, idx = M.find_entry(manifest, session_name)
	if not idx then
		return false, "'" .. session_name .. "' is not in workspace '" .. manifest.name .. "'"
	end
	table.remove(manifest.agents, idx)
	M.save(manifest, cwd)
	M.clear_overrides(manifest.name, session_name, nil, cwd)
	return true
end

------------------------------------------------------------------------
-- Per-workspace overrides
--
--   workspaces/<ws>/<session_name>/<file>
--
-- A member may override any of its agent's definition files for THIS
-- workspace only. At launch the global agent is mirrored into active_dir
-- first, then any override files are copied on top, so the hook (which
-- reads active_dir) sees the override whenever one exists and the global
-- file otherwise. Edits made from a live session are written to the
-- override, never to the global agent; `agent push` promotes them.
--
-- Keyed by SESSION name (the manifest entry), which equals the agent name
-- unless the same agent runs twice in one workspace — in which case each
-- copy gets its own overrides, as it must.
------------------------------------------------------------------------

local function agent_files()
	return require("nvim-agent.agent").AGENT_FILES
end

local function is_agent_file(file)
	for _, f in ipairs(agent_files()) do
		if f == file then
			return true
		end
	end
	return false
end

--- @param ws_name string
--- @param session_name string
--- @param cwd string|nil
--- @return string
function M.override_dir(ws_name, session_name, cwd)
	return M.workspaces_dir(cwd) .. "/" .. ws_name .. "/" .. session_name
end

--- @param ws_name string
--- @param session_name string
--- @param file string  one of agent.AGENT_FILES
--- @param cwd string|nil
--- @return string
function M.override_path(ws_name, session_name, file, cwd)
	return M.override_dir(ws_name, session_name, cwd) .. "/" .. file
end

--- Files currently overridden for a member, in AGENT_FILES order.
--- @return string[]
function M.list_overrides(ws_name, session_name, cwd)
	local out = {}
	for _, f in ipairs(agent_files()) do
		if vim.fn.filereadable(M.override_path(ws_name, session_name, f, cwd)) == 1 then
			table.insert(out, f)
		end
	end
	return out
end

--- Write (create or replace) one override file from `content`.
--- @return boolean ok, string|nil err
function M.write_override(ws_name, session_name, file, content, cwd)
	if not is_agent_file(file) then
		return false, "'" .. file .. "' is not an agent definition file"
	end
	local path = M.override_path(ws_name, session_name, file, cwd)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return false, "could not write " .. path
	end
	f:write(content)
	f:close()
	return true
end

--- Copy a file from `src_path` (typically a session's active_dir) into the
--- member's override for `file`. This is the copy-on-first-edit step: the
--- override starts as whatever the session currently has.
--- @return boolean ok, string|nil err
function M.copy_override_from(ws_name, session_name, file, src_path, cwd)
	local f = io.open(src_path, "r")
	if not f then
		return false, "cannot read " .. src_path
	end
	local content = f:read("*a")
	f:close()
	return M.write_override(ws_name, session_name, file, content, cwd)
end

--- Delete one override (file given) or all overrides (file nil) for a member.
function M.clear_overrides(ws_name, session_name, file, cwd)
	if file then
		local p = M.override_path(ws_name, session_name, file, cwd)
		if vim.fn.filereadable(p) == 1 then
			vim.fn.delete(p)
		end
		-- Drop the dir when it is now empty so the workspace stays tidy.
		local dir = M.override_dir(ws_name, session_name, cwd)
		if vim.fn.isdirectory(dir) == 1 and #vim.fn.readdir(dir) == 0 then
			vim.fn.delete(dir, "d")
		end
		return
	end
	local dir = M.override_dir(ws_name, session_name, cwd)
	if vim.fn.isdirectory(dir) == 1 then
		vim.fn.delete(dir, "rf")
	end
end

--- Copy every override the member has onto `target_dir` (a session
--- active_dir that already holds the global agent's files).
--- @return string[]  files that were applied
function M.apply_overrides(ws_name, session_name, target_dir, cwd)
	local applied = {}
	for _, f in ipairs(M.list_overrides(ws_name, session_name, cwd)) do
		local src = M.override_path(ws_name, session_name, f, cwd)
		vim.fn.mkdir(target_dir, "p")
		vim.fn.writefile(vim.fn.readfile(src, "b"), target_dir .. "/" .. f, "b")
		table.insert(applied, f)
	end
	return applied
end

------------------------------------------------------------------------
-- Live workspace for this Neovim instance
------------------------------------------------------------------------

--- The manifest currently loaded in this instance, or nil.
M.current = nil

--- @param manifest table|nil
function M.set_current(manifest)
	M.current = manifest
end

--- @return table|nil
function M.get_current()
	return M.current
end

return M
