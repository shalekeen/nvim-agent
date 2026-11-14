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
-- Agents are the ONLY unit of definition. A live session's active/ dir is
-- built from an agent (M.load) plus that workspace's override files
-- (workspace.apply_overrides). Edits made in a session land in the
-- overrides; M.save promotes a session's files back to the global agent
-- (`:NvimAgent agent push`). A permanently different variant is a copy
-- under a new name (M.copy).

local M = {}

local config = require("nvim-agent.config")

M.AGENT_FILES = {
	"role.md",
	"system_prompt.md",
	"user_notes.md",
	"persistent_dirs.json",
	"permissions.json",
	"config.json",
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

--- Runtime characteristics an agent definition can set in config.json.
--- Mirrored into the session like every other file, so a workspace can
--- override it per member. Unknown keys are ignored; invalid values fall
--- back to these defaults.
---
---   inbox_wakeups          boolean  true — nudge an idle agent whose mailbox
---                                   or trigger file has new content ("You
---                                   have pending messages..."). Set false
---                                   for agents that should only act when
---                                   addressed directly.
---   inbox_wakeup_interval  number   30   — seconds between those checks for
---                                   this agent (minimum 5). E.g. 300 for a
---                                   nudge at most every five minutes.
---   history                string   "persistent" | "fresh" — "fresh" starts
---                                   an empty work-history file every time
---                                   the agent's CLI launches (restart
---                                   included), instead of appending.
---   periodic               array    [] — prompts typed into the agent's
---                                   terminal on a schedule. Each item:
---                                     prompt    string  REQUIRED, the text sent
---                                     interval  number  REQUIRED, seconds (min 5)
---                                     when      "idle" | "always"  default "idle":
---                                               only send if the agent produced
---                                               no output for a whole interval,
---                                               so a prompt never lands mid-task
---                                   Invalid items are dropped.
M.DEFAULT_CONFIG = {
	inbox_wakeups = true,
	inbox_wakeup_interval = 30,
	history = "persistent",
	conversation = "resume",
	periodic = {},
}

M.MIN_WAKEUP_INTERVAL = 5

--- Read and validate an agent config from a directory (an agent's library
--- dir or a session's active_dir). Missing file → defaults.
--- @param dir string
--- @return table  { inbox_wakeups = boolean, history = "persistent"|"fresh" }
function M.read_config(dir)
	local out = vim.deepcopy(M.DEFAULT_CONFIG)
	local raw = dir and read_file(dir .. "/config.json")
	if not raw or raw:match("^%s*$") then
		return out
	end
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return out
	end
	if type(data.inbox_wakeups) == "boolean" then
		out.inbox_wakeups = data.inbox_wakeups
	end
	if type(data.inbox_wakeup_interval) == "number" and data.inbox_wakeup_interval >= M.MIN_WAKEUP_INTERVAL then
		out.inbox_wakeup_interval = math.floor(data.inbox_wakeup_interval)
	end
	if data.history == "fresh" or data.history == "persistent" then
		out.history = data.history
	end
	if data.conversation == "fresh" or data.conversation == "resume" then
		out.conversation = data.conversation
	end
	if type(data.periodic) == "table" then
		out.periodic = {}
		for _, item in ipairs(data.periodic) do
			if
				type(item) == "table"
				and type(item.prompt) == "string"
				and not item.prompt:match("^%s*$")
				and type(item.interval) == "number"
				and item.interval >= M.MIN_WAKEUP_INTERVAL
			then
				table.insert(out.periodic, {
					prompt = item.prompt,
					interval = math.floor(item.interval),
					when = item.when == "always" and "always" or "idle",
				})
			end
		end
	end
	return out
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
	write_file(dir .. "/config.json", vim.json.encode(M.DEFAULT_CONFIG))
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
