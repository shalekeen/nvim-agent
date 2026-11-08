local M = {}

local config = require("nvim-agent.config")

--- Generate a random v4 UUID. Prefers libuv's CSPRNG; falls back to
--- math.random seeded from the clock + pid if uv.random is unavailable.
local function generate_uuid()
	local bytes
	local ok, raw = pcall(function()
		return vim.loop.random(16)
	end)
	if ok and type(raw) == "string" and #raw == 16 then
		bytes = { raw:byte(1, 16) }
	else
		math.randomseed(os.time() + (vim.loop.hrtime() % 1000000) + vim.fn.getpid())
		bytes = {}
		for i = 1, 16 do
			bytes[i] = math.random(0, 255)
		end
	end
	bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40) -- version 4
	bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80) -- RFC 4122 variant
	local unpack_fn = table.unpack or unpack
	return string.format(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		unpack_fn(bytes)
	)
end

--- Unique ID for this Neovim instance, minted once when nvim-agent loads.
--- Every per-instance path derives from it: the session tree under
--- <base_dir>/sessions/<instance_id>/ and the project runtime tree under
--- <cwd>/.nvim-agent/instances/<instance_id>/. It is forwarded to the agent
--- CLI and MCP server as NVIM_AGENT_INSTANCE_ID / NVIM_AGENT_RUNTIME_DIR so
--- two Neovim instances open on the same project never share peer state.
--- A UUID rather than the PID so ids stay unique across reboots / PID reuse
--- and stale dirs remain attributable to one specific launch.
M.instance_id = generate_uuid()

--- Owning OS process id. Kept for diagnostics and adapter visibility only;
--- no path is derived from it.
M.window_id = vim.fn.getpid()

M.sessions = {} -- keyed by compound string id, e.g. "485293847_main"
M.current_id = nil -- compound string id of last-focused session

local next_instance = 1 -- sequential counter (used for display ordering only)

--- Path to the process-level shared directory for this Neovim instance.
--- All sessions within the same process share this directory (ephemeral.json lives here).
local function process_dir_path()
	return config.get().base_dir .. "/sessions/" .. M.instance_id
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

	-- Compound ID uses name for uniqueness: <instance_id>_<name>
	local id = M.instance_id .. "_" .. name
	local pdir = process_dir_path()
	local dir = pdir .. "/" .. name
	local active_dir = dir .. "/active"
	vim.fn.mkdir(active_dir, "p") -- also creates pdir via "p"

	local session = {
		id = id, -- compound string, used as table key
		instance_num = instance_num, -- sequential int for display ordering only
		name = name, -- user-visible identifier; used as dir name
		instance_id = M.instance_id, -- which Neovim instance owns this session
		window_id = M.window_id, -- owning process id (diagnostics only)
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
	-- runtime dir. Scoped to THIS instance's runtime dir, so closing "main"
	-- here never touches a same-named session in another Neovim.
	if sess then
		local workspace_mod = require("nvim-agent.workspace")
		local cwd = vim.fn.getcwd()
		local status_file = workspace_mod.instance_runtime_dir(cwd) .. "/status/" .. sess.name .. ".json"
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
