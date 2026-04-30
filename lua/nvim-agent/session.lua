local M = {}

local config = require("nvim-agent.config")

--- Unique ID for this Neovim process.
--- Using the OS process ID guarantees no two simultaneously-running Neovim
--- windows share the same window_id, so their session directories never collide.
M.window_id = vim.fn.getpid()

M.sessions = {} -- keyed by compound string id, e.g. "485293847_main"
M.current_id = nil -- compound string id of last-focused session

local next_instance = 1 -- sequential counter (used for display ordering only)

--- Path to the process-level shared directory for this Neovim instance.
--- All sessions within the same process share this directory (ephemeral.json lives here).
local function process_dir_path()
	return config.get().base_dir .. "/sessions/" .. M.window_id
end

--- Return the process-level shared directory path.
--- @return string
function M.get_process_dir()
	return process_dir_path()
end

--- Create a new session with its own filesystem directory.
--- The first session in a process defaults to name "main" if no name is given.
--- All subsequent sessions require an explicit name.
--- Returns nil + error string on failure.
--- @param flavor string
--- @param checkpoint string|nil
--- @param name string|nil  User-chosen name; auto-set to "main" for the first session
--- @return table|nil, string|nil
function M.create(flavor, checkpoint, name)
	local sess_count = 0
	for _ in pairs(M.sessions) do
		sess_count = sess_count + 1
	end

	-- First session gets "main" by default; all others must be named
	if not name or name == "" then
		if sess_count == 0 then
			name = "main"
		else
			return nil, "session name is required"
		end
	end

	-- Reject duplicate names within this process
	for _, s in pairs(M.sessions) do
		if s.name == name then
			return nil, "session '" .. name .. "' already exists"
		end
	end

	local instance_num = next_instance
	next_instance = next_instance + 1

	-- Compound ID uses name for uniqueness: <window_id>_<name>
	local id = M.window_id .. "_" .. name
	local pdir = process_dir_path()
	local dir = pdir .. "/" .. name
	local active_dir = dir .. "/active"
	vim.fn.mkdir(active_dir, "p") -- also creates pdir via "p"

	local session = {
		id = id, -- compound string, used as table key
		instance_num = instance_num, -- sequential int for display ordering only
		name = name, -- user-visible identifier; used as dir name
		window_id = M.window_id, -- which Neovim process owns this session
		process_dir = pdir, -- shared process-level dir (ephemeral.json lives here)
		flavor = flavor or "agent",
		checkpoint = checkpoint,
		dir = dir,
		active_dir = active_dir,
		bufnr = nil,
		winnr = nil,
		jobid = nil,
	}

	M.sessions[id] = session
	if M.current_id == nil then
		M.current_id = id
	end
	return session
end

--- Get session by compound string ID.
--- @param id string  e.g. "485293847_main"
--- @return table|nil
function M.get(id)
	return M.sessions[id]
end

--- Get session by user-visible name (e.g. "main", "research").
--- @param name string
--- @return table|nil
function M.get_by_name(name)
	for _, sess in pairs(M.sessions) do
		if sess.name == name then
			return sess
		end
	end
	return nil
end

--- Get the currently focused session (last agent terminal entered).
--- @return table|nil
function M.get_current()
	if M.current_id then
		return M.sessions[M.current_id]
	end
	return nil
end

--- Mark a session as current. Called on BufEnter of that session's terminal.
--- @param id string  Compound session ID
function M.set_current(id)
	if M.sessions[id] then
		M.current_id = id
	end
end

--- Return all sessions owned by this process, sorted by creation order.
--- @return table[]
function M.list()
	local result = {}
	for _, sess in pairs(M.sessions) do
		table.insert(result, sess)
	end
	table.sort(result, function(a, b)
		return a.instance_num < b.instance_num
	end)
	return result
end

--- Find a session by its terminal buffer number.
--- @param bufnr number
--- @return table|nil
function M.find_by_bufnr(bufnr)
	for _, sess in pairs(M.sessions) do
		if sess.bufnr == bufnr then
			return sess
		end
	end
	return nil
end

--- Close a session: stop its job, delete its buffer, remove from registry,
--- and clean up the agent's status file so peers no longer see it.
--- @param id string  Compound session ID
function M.close(id)
	local sess = M.sessions[id]
	require("nvim-agent.terminal").cleanup(id)

	-- Remove the agent's status file so peers stop discovering it.
	-- We always check, regardless of whether the workspace dir still exists:
	-- terminal.lua writes the status file unconditionally, so leaking it after
	-- close would leave a phantom agent visible to any peer that still sees the
	-- runtime dir.
	if sess then
		local workspace_mod = require("nvim-agent.workspace")
		local cwd = vim.fn.getcwd()
		local status_file = workspace_mod.runtime_dir(cwd) .. "/status/" .. sess.name .. ".json"
		if vim.fn.filereadable(status_file) == 1 then
			vim.fn.delete(status_file)
		end
	end

	M.sessions[id] = nil
	if M.current_id == id then
		M.current_id = nil
		for other_id in pairs(M.sessions) do
			M.current_id = other_id
			break
		end
	end
end

return M
