-- Per-Neovim-instance session registry.
--
-- A session is one running (or exited) agent: a name, the global agent it
-- was built from, an active_dir mirroring that agent's files, and — while
-- the CLI is running — a terminal buffer, window and job.
--
-- Liveness lives here; membership lives in the workspace manifest. A
-- session whose CLI exits stays registered with state = "exited" so it can
-- be relaunched into the same active_dir.

local M = {}

local config = require("nvim-agent.config")
local uv = vim.uv or vim.loop

--- Generate a random v4 UUID. Prefers libuv's CSPRNG; falls back to
--- math.random seeded from the clock + pid if uv.random is unavailable.
local function generate_uuid()
	local bytes
	local ok, raw = pcall(function()
		return uv.random(16)
	end)
	if ok and type(raw) == "string" and #raw == 16 then
		bytes = { raw:byte(1, 16) }
	else
		math.randomseed(os.time() + (uv.hrtime() % 1000000) + uv.os_getpid())
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
M.instance_id = generate_uuid()

M.sessions = {} -- keyed by compound string id "<instance_id>_<name>"
M.current_id = nil -- id of the last-focused session

local next_instance = 1 -- creation counter, display ordering only

local function process_dir_path()
	return config.get().base_dir .. "/sessions/" .. M.instance_id
end

--- Create a session for `agent_name` under the session name `name`.
--- Returns nil + error on a duplicate name.
--- @param name string        Session name (unique within this instance)
--- @param agent_name string  Global agent the session is built from
--- @return table|nil, string|nil
function M.create(name, agent_name)
	if not name or name == "" then
		return nil, "session name is required"
	end
	if not agent_name or agent_name == "" then
		return nil, "agent name is required"
	end
	for _, s in pairs(M.sessions) do
		if s.name == name then
			return nil, "session '" .. name .. "' already exists"
		end
	end

	local instance_num = next_instance
	next_instance = next_instance + 1

	local id = M.instance_id .. "_" .. name
	local pdir = process_dir_path()
	local dir = pdir .. "/" .. name
	local active_dir = dir .. "/active"
	vim.fn.mkdir(active_dir, "p")

	local session = {
		id = id,
		instance_num = instance_num,
		name = name,
		agent = agent_name,
		state = "created", -- "created" | "running" | "exited"
		instance_id = M.instance_id,
		process_dir = pdir,
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

--- @param id string
--- @return table|nil
function M.get(id)
	return M.sessions[id]
end

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

--- @param active_dir string
--- @return table|nil
function M.get_by_active_dir(active_dir)
	for _, sess in pairs(M.sessions) do
		if sess.active_dir == active_dir then
			return sess
		end
	end
	return nil
end

--- Last-focused session, or nil.
--- @return table|nil
function M.get_current()
	if M.current_id then
		return M.sessions[M.current_id]
	end
	return nil
end

--- @param id string
function M.set_current(id)
	if M.sessions[id] then
		M.current_id = id
	end
end

--- All sessions in creation order.
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

--- True while the CLI process is alive.
--- @param sess table
--- @return boolean
function M.is_running(sess)
	return sess ~= nil and sess.jobid ~= nil
end

--- Path of this session's peer-visible status file.
--- @param sess table
--- @return string
function M.status_path(sess)
	return require("nvim-agent.workspace").instance_runtime_dir(vim.fn.getcwd())
		.. "/status/"
		.. sess.name
		.. ".json"
end

--- Delete the status file so peers stop discovering (and delegating to)
--- this session. Called on close and on CLI exit.
--- @param sess table
function M.remove_status(sess)
	local path = M.status_path(sess)
	if vim.fn.filereadable(path) == 1 then
		vim.fn.delete(path)
	end
end

--- Record that the CLI process ended on its own. The session stays
--- registered (it is still a workspace member) and can be relaunched.
--- @param id string
--- @param code number|nil  exit code
function M.mark_exited(id, code)
	local sess = M.sessions[id]
	if not sess then
		return
	end
	sess.jobid = nil
	sess.state = "exited"
	sess.exit_code = code
	M.remove_status(sess)
end

--- Fully close a session: stop its job, delete its buffer, remove its
--- status file and drop it from the registry. This is the liveness half of
--- "remove from workspace"; the caller handles the manifest.
--- @param id string
function M.close(id)
	local sess = M.sessions[id]
	require("nvim-agent.terminal").cleanup(id)
	if sess then
		M.remove_status(sess)
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
