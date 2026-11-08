-- Global agent library.
--
-- An agent is a directory of files under ~/.nvim-agent/agents/<name>/.
-- The directory layout IS the schema; there is no in-memory class.
--
--   ~/.nvim-agent/agents/
--     <name>/                      user-defined agent
--       role.md                    REQUIRED — one short paragraph. Guides the
--                                  agent's own behaviour (it opens the system
--                                  prompt) AND is what peers see when deciding
--                                  whom to delegate to.
--       system_prompt.md           behaviour prompt (seeded from config.default_system_prompt)
--       user_notes.md              standing user notes
--       persistent_dirs.json       pinned code paths: [{ tag, path, description }]
--       permissions.json           optional, adapter-specific tool permissions
--     spawned/<name>/              agents created at runtime by the spawn_agent
--                                  MCP tool; same files, listed in their own
--                                  section so they don't crowd out your own.
--
-- Agents are the ONLY unit of definition. A project that wants a variant of
-- an agent copies it under a new name (M.copy) and edits the copy. A live
-- session's active/ dir is a mirror of its agent: edits made there are
-- written straight back with M.save.

local M = {}

local config = require("nvim-agent.config")

M.AGENT_FILES = {
	"role.md",
	"system_prompt.md",
	"user_notes.md",
	"persistent_dirs.json",
	"permissions.json",
}

M.SPAWNED_DIRNAME = "spawned"

local DEFAULT_NOTES = "# User Notes\n\nAdd behavioral notes here that you want the coding agent to respect.\n"

------------------------------------------------------------------------
-- File helpers
------------------------------------------------------------------------

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function write_file(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function copy_if_present(src, dst)
	if vim.fn.filereadable(src) == 1 then
		vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
		vim.fn.writefile(vim.fn.readfile(src, "b"), dst, "b")
		return true
	end
	return false
end

local function is_blank(s)
	return s == nil or s:match("^%s*$") ~= nil
end

------------------------------------------------------------------------
-- Paths
------------------------------------------------------------------------

--- @return string  ~/.nvim-agent/agents
function M.base_dir()
	return config.get().base_dir .. "/agents"
end

--- @return string  ~/.nvim-agent/agents/spawned
function M.spawned_dir()
	return M.base_dir() .. "/" .. M.SPAWNED_DIRNAME
end

--- Validate an agent name: non-empty, no path separators, not reserved.
--- @param name any
--- @return boolean, string|nil
function M.validate_name(name)
	if type(name) ~= "string" or name == "" then
		return false, "agent name is required"
	end
	if name:find("/", 1, true) or name:find("\\", 1, true) then
		return false, "agent name may not contain path separators"
	end
	if name:match("^%.") then
		return false, "agent name may not start with '.'"
	end
	if name == M.SPAWNED_DIRNAME then
		return false, "'" .. M.SPAWNED_DIRNAME .. "' is reserved"
	end
	return true
end

--- Directory an agent WOULD live in (does not check existence).
--- @param name string
--- @param spawned boolean|nil
--- @return string
function M.dir(name, spawned)
	if spawned then
		return M.spawned_dir() .. "/" .. name
	end
	return M.base_dir() .. "/" .. name
end

--- Resolve an agent by name. User agents shadow spawned ones.
--- @param name string
--- @return string|nil dir, boolean|nil spawned
function M.resolve(name)
	local ok = M.validate_name(name)
	if not ok then
		return nil
	end
	local user_dir = M.dir(name, false)
	if vim.fn.isdirectory(user_dir) == 1 then
		return user_dir, false
	end
	local spawned_dir = M.dir(name, true)
	if vim.fn.isdirectory(spawned_dir) == 1 then
		return spawned_dir, true
	end
	return nil
end

--- @param name string
--- @return boolean
function M.exists(name)
	return M.resolve(name) ~= nil
end

------------------------------------------------------------------------
-- Listing
------------------------------------------------------------------------

local function list_dir(base, spawned)
	if vim.fn.isdirectory(base) ~= 1 then
		return {}
	end
	local out = {}
	for _, entry in ipairs(vim.fn.readdir(base)) do
		local path = base .. "/" .. entry
		if
			not entry:match("^%.")
			and entry ~= M.SPAWNED_DIRNAME
			and vim.fn.isdirectory(path) == 1
		then
			table.insert(out, {
				name = entry,
				spawned = spawned,
				role = M.read_role(entry, spawned),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- List every agent. User-defined agents first (sorted), then spawned ones
--- (sorted), so UIs can render the two sections in order.
--- @return table[]  { { name, spawned = boolean, role = string|nil } }
function M.list()
	local all = list_dir(M.base_dir(), false)
	for _, a in ipairs(list_dir(M.spawned_dir(), true)) do
		table.insert(all, a)
	end
	return all
end

--- Read an agent's role text (trailing whitespace trimmed), or nil.
--- @param name string
--- @param spawned boolean|nil  nil → resolve
--- @return string|nil
function M.read_role(name, spawned)
	local dir
	if spawned == nil then
		dir = M.resolve(name)
	else
		dir = M.dir(name, spawned)
	end
	if not dir then
		return nil
	end
	local role = read_file(dir .. "/role.md")
	if is_blank(role) then
		return nil
	end
	return (role:gsub("%s+$", ""))
end

------------------------------------------------------------------------
-- Create / copy / delete
------------------------------------------------------------------------

--- Create a new agent.
--- @param name string
--- @param opts table  {
---   role = string            REQUIRED
---   system_prompt = string   default: config.default_system_prompt
---   user_notes = string      default: a short "# User Notes" stub
---   persistent_dirs = string default: "[]"
---   spawned = boolean        default: false
--- }
--- @return boolean ok, string|nil err
function M.create(name, opts)
	opts = opts or {}
	local ok, err = M.validate_name(name)
	if not ok then
		return false, err
	end
	if is_blank(opts.role) then
		return false, "role is required: a short description of what this agent does"
	end
	if M.exists(name) then
		return false, "agent '" .. name .. "' already exists"
	end

	local dir = M.dir(name, opts.spawned)
	vim.fn.mkdir(dir, "p")
	local cfg = config.get()
	write_file(dir .. "/role.md", opts.role:gsub("%s+$", "") .. "\n")
	write_file(dir .. "/system_prompt.md", opts.system_prompt or cfg.default_system_prompt or "")
	write_file(dir .. "/user_notes.md", opts.user_notes or DEFAULT_NOTES)
	write_file(dir .. "/persistent_dirs.json", opts.persistent_dirs or "[]")
	return true
end

--- Copy an agent to a new name. The copy is always a user agent (even when
--- the source is spawned) — copying is how you "adopt" a spawned agent or
--- make a project-specific variant.
--- @param src string
--- @param dst string
--- @return boolean ok, string|nil err
function M.copy(src, dst)
	local src_dir = M.resolve(src)
	if not src_dir then
		return false, "agent '" .. src .. "' not found"
	end
	local ok, err = M.validate_name(dst)
	if not ok then
		return false, err
	end
	if M.exists(dst) then
		return false, "agent '" .. dst .. "' already exists"
	end
	local dst_dir = M.dir(dst, false)
	vim.fn.mkdir(dst_dir, "p")
	for _, f in ipairs(M.AGENT_FILES) do
		copy_if_present(src_dir .. "/" .. f, dst_dir .. "/" .. f)
	end
	return true
end

--- Delete an agent definition.
--- @param name string
--- @return boolean ok, string|nil err
function M.delete(name)
	local dir = M.resolve(name)
	if not dir then
		return false, "agent '" .. name .. "' not found"
	end
	vim.fn.delete(dir, "rf")
	return true
end

------------------------------------------------------------------------
-- Session mirroring
------------------------------------------------------------------------

--- Copy an agent's files into a session active_dir. Files the agent does not
--- define are left alone (context.write_all seeds safe fallbacks for them).
--- @param name string
--- @param target_dir string
--- @return boolean ok, string|nil err
function M.load(name, target_dir)
	local dir = M.resolve(name)
	if not dir then
		return false, "agent '" .. name .. "' not found"
	end
	vim.fn.mkdir(target_dir, "p")
	for _, f in ipairs(M.AGENT_FILES) do
		copy_if_present(dir .. "/" .. f, target_dir .. "/" .. f)
	end
	return true
end

--- Write a session active_dir back into its agent definition. Only files
--- present in the source are written; nothing is deleted from the agent.
--- The agent must already exist — this never creates one.
--- @param name string
--- @param source_dir string
--- @return boolean ok, string|nil err
function M.save(name, source_dir)
	local dir = M.resolve(name)
	if not dir then
		return false, "agent '" .. name .. "' not found"
	end
	for _, f in ipairs(M.AGENT_FILES) do
		copy_if_present(source_dir .. "/" .. f, dir .. "/" .. f)
	end
	return true
end

return M
