local M = {}

local config = require("nvim-agent.config")

local CONTEXT_FILES = { "system_prompt.md", "user_notes.md", "persistent_dirs.json" }
local META_FILE = ".flavor_meta.json"

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

local function copy_file(src, dst)
	local content = read_file(src)
	if content then
		write_file(dst, content)
		return true
	end
	return false
end

local function flavor_dir(name)
	return config.get().base_dir .. "/" .. name
end

local function write_meta(flavor_name, checkpoint_name, active_dir)
	if not active_dir then
		return
	end
	local meta = { flavor = flavor_name, checkpoint = checkpoint_name }
	write_file(active_dir .. "/" .. META_FILE, vim.json.encode(meta))
end

-- Exposed so workspace agent creation can write meta without loading a full flavor.
M.write_meta = write_meta

local function read_meta(active_dir)
	if not active_dir then
		return nil
	end
	local content = read_file(active_dir .. "/" .. META_FILE)
	if not content or content == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

local function is_reserved(name)
	return name == "active" or name == "sessions" or name == "hooks" or name == "agent_templates"
end

--- Create a new flavor by copying current active_dir context as its base.
--- @param name string
--- @param active_dir string|nil  Source active dir (defaults to global active_dir)
function M.create(name, active_dir)
	if is_reserved(name) then
		vim.notify("nvim-agent: '" .. name .. "' is reserved", vim.log.levels.ERROR)
		return false
	end
	local dir = flavor_dir(name)
	if vim.fn.isdirectory(dir) == 1 then
		vim.notify("nvim-agent: flavor '" .. name .. "' already exists", vim.log.levels.ERROR)
		return false
	end
	vim.fn.mkdir(dir, "p")
	vim.fn.mkdir(dir .. "/checkpoints", "p")

	-- Seed flavor files: copy from active_dir if given, else use config defaults
	if active_dir then
		for _, fname in ipairs(CONTEXT_FILES) do
			local src = active_dir .. "/" .. fname
			local dst = dir .. "/" .. fname
			if vim.fn.filereadable(src) == 1 then
				copy_file(src, dst)
			else
				write_file(dst, fname:match("%.json$") and "[]" or "")
			end
		end
	else
		local cfg = config.get()
		write_file(dir .. "/system_prompt.md", cfg.default_system_prompt or "")
		write_file(
			dir .. "/user_notes.md",
			"# User Notes\n\nAdd behavioral notes here that you want the coding agent to respect.\n"
		)
		write_file(dir .. "/persistent_dirs.json", "[]")
	end

	write_meta(name, nil, active_dir)
	return true
end

--- Load a flavor (and optionally a checkpoint) into active_dir.
--- @param name string
--- @param checkpoint_name string|nil
--- @param active_dir string|nil  Destination active dir (defaults to global active_dir)
function M.load(name, checkpoint_name, active_dir)
	local dir = flavor_dir(name)
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("nvim-agent: flavor '" .. name .. "' not found", vim.log.levels.ERROR)
		return false
	end

	if checkpoint_name then
		-- Delegate to checkpoint module for merge-then-copy
		local cp = require("nvim-agent.flavor.checkpoint")
		cp.load(name, checkpoint_name, active_dir)
		return true
	end

	if not active_dir then
		vim.notify("nvim-agent: active_dir required to load flavor", vim.log.levels.ERROR)
		return false
	end

	-- Copy base files to active_dir (with validation)
	for _, fname in ipairs(CONTEXT_FILES) do
		local src = dir .. "/" .. fname
		local dst = active_dir .. "/" .. fname

		if vim.fn.filereadable(src) == 1 then
			copy_file(src, dst)
		else
			vim.notify("nvim-agent: warning - missing file in flavor: " .. fname, vim.log.levels.WARN)
			if fname:match("%.json$") then
				write_file(dst, "[]")
			else
				write_file(dst, "")
			end
		end
	end

	write_meta(name, nil, active_dir)
	return true
end

--- Save active_dir context back to a named flavor.
--- @param name string
--- @param active_dir string|nil  Source active dir (defaults to global active_dir)
function M.save(name, active_dir)
	if not active_dir then
		vim.notify("nvim-agent: active_dir required to save flavor", vim.log.levels.ERROR)
		return false
	end
	local dir = flavor_dir(name)
	if vim.fn.isdirectory(dir) ~= 1 then
		-- Create the flavor directory if saving for the first time
		vim.fn.mkdir(dir, "p")
		vim.fn.mkdir(dir .. "/checkpoints", "p")
	end

	for _, fname in ipairs(CONTEXT_FILES) do
		copy_file(active_dir .. "/" .. fname, dir .. "/" .. fname)
	end

	write_meta(name, nil, active_dir)
	return true
end

function M.list()
	local base = config.get().base_dir
	if vim.fn.isdirectory(base) ~= 1 then
		return {}
	end
	local entries = vim.fn.readdir(base)
	local flavors = {}
	for _, entry in ipairs(entries) do
		if not is_reserved(entry) and not entry:match("^%.") and vim.fn.isdirectory(base .. "/" .. entry) == 1 then
			table.insert(flavors, entry)
		end
	end
	table.sort(flavors)
	return flavors
end

--- Check whether a flavor with the given name exists.
--- @param name string
--- @return boolean
function M.list_contains(name)
	local dir = flavor_dir(name)
	return vim.fn.isdirectory(dir) == 1
end

function M.delete(name)
	if is_reserved(name) then
		vim.notify("nvim-agent: cannot delete reserved directory", vim.log.levels.ERROR)
		return false
	end
	local dir = flavor_dir(name)
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("nvim-agent: flavor '" .. name .. "' not found", vim.log.levels.ERROR)
		return false
	end

	vim.fn.delete(dir, "rf")
	return true
end

function M.rename(old_name, new_name)
	if is_reserved(old_name) or is_reserved(new_name) then
		vim.notify("nvim-agent: cannot use reserved name", vim.log.levels.ERROR)
		return false
	end
	local old_dir = flavor_dir(old_name)
	local new_dir = flavor_dir(new_name)
	if vim.fn.isdirectory(old_dir) ~= 1 then
		vim.notify("nvim-agent: flavor '" .. old_name .. "' not found", vim.log.levels.ERROR)
		return false
	end
	if vim.fn.isdirectory(new_dir) == 1 then
		vim.notify("nvim-agent: flavor '" .. new_name .. "' already exists", vim.log.levels.ERROR)
		return false
	end
	vim.fn.rename(old_dir, new_dir)
	return true
end

--- Return the active flavor name for the given active_dir.
--- @param active_dir string|nil
--- @return string|nil
function M.current(active_dir)
	local meta = read_meta(active_dir)
	if meta then
		return meta.flavor
	end
	return nil
end

--- Return the active checkpoint name for the given active_dir.
--- @param active_dir string|nil
--- @return string|nil
function M.current_checkpoint(active_dir)
	local meta = read_meta(active_dir)
	if meta then
		return meta.checkpoint
	end
	return nil
end

return M
