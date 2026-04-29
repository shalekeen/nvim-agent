-- Filesystem-based per-file locking using atomic mkdir.
-- On POSIX, mkdir fails atomically if the directory already exists,
-- making it a reliable cross-process lock primitive without O_EXCL.

local M = {}

local LOCK_BASE = "/tmp/nvim-agent-locks"

--- Sanitize a filepath into a safe directory name for the lock.
--- Uses the absolute path with slashes replaced by double underscores.
local function lock_key(filepath)
	-- Resolve to absolute path via realpath (handles ./foo, symlinks, etc.)
	local handle = io.popen("realpath " .. "'" .. filepath:gsub("'", "'\\''") .. "' 2>/dev/null")
	if handle then
		local resolved = handle:read("*l")
		handle:close()
		if resolved and resolved ~= "" then
			filepath = resolved
		end
	end
	return filepath:gsub("/", "__")
end

--- Return the lock directory path for a given filepath.
local function lock_dir(filepath)
	return LOCK_BASE .. "/" .. lock_key(filepath)
end

--- Write lock metadata (agent name, PID, timestamp) into the lock directory.
local function write_info(dir, agent)
	local f = io.open(dir .. "/info", "w")
	if f then
		f:write(string.format("agent=%s\npid=%d\ntime=%d\n", agent or "unknown", tonumber(os.getenv("PPID")) or 0, os.time()))
		f:close()
	end
end

--- Read lock metadata. Returns { agent, pid, time } or nil.
local function read_info(dir)
	local f = io.open(dir .. "/info", "r")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	local info = {}
	info.agent = data:match("agent=([^\n]+)")
	info.pid = tonumber(data:match("pid=(%d+)"))
	info.time = tonumber(data:match("time=(%d+)"))
	return info
end

--- Force-remove a stale lock directory.
local function force_remove(dir)
	os.remove(dir .. "/info")
	os.execute("rmdir '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
end

--- Acquire a lock on a filepath.
--- Options:
---   agent       : agent name for diagnostics (default "unknown")
---   timeout_sec : stale lock threshold in seconds (default 5)
---   retries     : number of attempts (default 10)
---   delay_ms    : milliseconds between retries (default 200)
--- Returns true on success, or false + error message.
function M.acquire(filepath, opts)
	opts = opts or {}
	local agent = opts.agent or "unknown"
	local timeout_sec = opts.timeout_sec or 5
	local retries = opts.retries or 5
	local delay_ms = opts.delay_ms or 100

	os.execute("mkdir -p '" .. LOCK_BASE:gsub("'", "'\\''") .. "'")
	local dir = lock_dir(filepath)

	for attempt = 1, retries do
		-- mkdir is atomic: succeeds only if directory did not exist
		local ok = os.execute("mkdir '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
		-- Lua 5.1 returns 0 on success; Lua 5.3+ returns true
		if ok == 0 or ok == true then
			write_info(dir, agent)
			return true
		end

		-- Lock exists — check if stale
		local info = read_info(dir)
		if info and info.time and (os.time() - info.time) > timeout_sec then
			force_remove(dir)
			-- Retry immediately after removing stale lock
			local ok2 = os.execute("mkdir '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
			if ok2 == 0 or ok2 == true then
				write_info(dir, agent)
				return true
			end
		end

		-- Wait before retrying
		if attempt < retries then
			os.execute(string.format("sleep %.3f", delay_ms / 1000))
		end
	end

	-- All retries exhausted
	local info = read_info(dir)
	local holder = info and info.agent or "unknown"
	return false, string.format("file locked by agent '%s' — try again shortly", holder)
end

--- Release a lock on a filepath. Idempotent.
function M.release(filepath)
	local dir = lock_dir(filepath)
	os.remove(dir .. "/info")
	os.execute("rmdir '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
end

return M
