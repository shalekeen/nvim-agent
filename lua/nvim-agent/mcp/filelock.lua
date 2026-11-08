-- Filesystem-based per-file locking using atomic mkdir.
-- On POSIX, mkdir fails atomically if the directory already exists,
-- making it a reliable cross-process lock primitive without O_EXCL.
--
-- Runs inside `nvim -l` (the MCP server) and inside the parent Neovim, so
-- libuv is always available: no shell-outs.

local M = {}

local uv = vim.uv or vim.loop

local LOCK_BASE = "/tmp/nvim-agent-locks"

--- Map a filepath to a lock directory name. Resolves the PARENT directory
--- (the file itself may not exist yet, e.g. the first write of a status
--- file) so relative paths and symlinked dirs map to the same lock from
--- every process. The key is a hash plus the basename: a flattened full
--- path could exceed NAME_MAX and make every acquire fail with ENAMETOOLONG.
local function lock_key(filepath)
	local parent = uv.fs_realpath(vim.fn.fnamemodify(filepath, ":h"))
	local resolved = parent and (parent .. "/" .. vim.fn.fnamemodify(filepath, ":t")) or filepath
	local tail = vim.fn.fnamemodify(filepath, ":t"):gsub("[^%w%.%-_]", "_"):sub(1, 64)
	return vim.fn.sha256(resolved):sub(1, 32) .. "-" .. tail
end

local function lock_dir(filepath)
	return LOCK_BASE .. "/" .. lock_key(filepath)
end

--- Atomic create. Returns true only if WE created the directory.
local function try_mkdir(dir)
	return uv.fs_mkdir(dir, 448) ~= nil -- 0700
end

--- Write lock metadata (agent name, PID, timestamp) into the lock directory.
local function write_info(dir, agent)
	local f = io.open(dir .. "/info", "w")
	if f then
		f:write(string.format("agent=%s\npid=%d\ntime=%d\n", agent or "unknown", uv.os_getpid(), os.time()))
		f:close()
	end
end

--- Read lock metadata. Returns { agent, pid, time } or nil.
local function read_info(dir)
	local f = io.open(dir .. "/info", "r")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return {
		agent = data:match("agent=([^\n]+)"),
		pid = tonumber(data:match("pid=(%d+)")),
		time = tonumber(data:match("time=(%d+)")),
	}
end

--- Reclaim a stale lock directory. Two waiters may both judge the lock
--- stale; only one may reclaim it, or both would then mkdir and both "hold"
--- the lock. rename is atomic, so whoever renames the stale dir away wins
--- and removes it; the loser's rename fails and it simply retries.
local function reclaim_stale(dir)
	local tomb = string.format("%s.stale.%d.%d", dir, uv.os_getpid(), uv.hrtime())
	if not uv.fs_rename(dir, tomb) then
		return false
	end
	os.remove(tomb .. "/info")
	uv.fs_rmdir(tomb)
	return true
end

--- Acquire a lock on a filepath.
--- Options:
---   agent       : agent name for diagnostics (default "unknown")
---   timeout_sec : stale lock threshold in seconds (default 5)
---   retries     : number of attempts (default 5)
---   delay_ms    : milliseconds between retries (default 100)
--- Returns true on success, or false + error message.
function M.acquire(filepath, opts)
	opts = opts or {}
	local agent = opts.agent or "unknown"
	local timeout_sec = opts.timeout_sec or 5
	local retries = opts.retries or 5
	local delay_ms = opts.delay_ms or 100

	vim.fn.mkdir(LOCK_BASE, "p")
	local dir = lock_dir(filepath)

	for attempt = 1, retries do
		if try_mkdir(dir) then
			write_info(dir, agent)
			return true
		end

		-- Lock exists — reclaim it if its holder looks dead.
		local info = read_info(dir)
		if info and info.time and (os.time() - info.time) > timeout_sec then
			if reclaim_stale(dir) and try_mkdir(dir) then
				write_info(dir, agent)
				return true
			end
		end

		if attempt < retries then
			uv.sleep(delay_ms)
		end
	end

	local info = read_info(dir)
	local holder = info and info.agent or "unknown"
	return false, string.format("file locked by agent '%s' — try again shortly", holder)
end

--- Release a lock on a filepath. Idempotent.
function M.release(filepath)
	local dir = lock_dir(filepath)
	os.remove(dir .. "/info")
	uv.fs_rmdir(dir)
end

return M
