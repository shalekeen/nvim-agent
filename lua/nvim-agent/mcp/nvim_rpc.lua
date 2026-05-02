-- Neovim RPC wrapper using shell commands
-- Uses nvim --server --remote-expr to communicate with Neovim
--
-- DESIGN: Arbitrary user content (file text, commands, paths with special chars)
-- is passed to Neovim via temp files, never embedded in Lua code strings.
-- This avoids the multi-layer escaping conflict between Lua's \' and
-- VimScript's '' escaping conventions inside luaeval().
-- Only simple safe values (numbers, booleans, temp file paths) are
-- embedded directly into the Lua code strings.

local M = {}

local json = vim.json

-- Decode a JSON response from --remote-expr. Returns value or (nil, err).
local function decode_response(result)
	local ok, data = pcall(json.decode, result)
	if not ok then
		return nil, "JSON decode: " .. tostring(data)
	end
	return data
end

-- Unique sequence number for temp file names
local _tmp_seq = 0

local function shell_escape(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function get_nvim_address()
	-- Prefer NVIM_AGENT_NVIM_ADDR; fall back to NVIM_LISTEN_ADDRESS for
	-- backward compatibility. The new var exists because `nvim -l` (used to
	-- run this script) hijacks NVIM_LISTEN_ADDRESS for its own server bind.
	local addr = os.getenv("NVIM_AGENT_NVIM_ADDR") or os.getenv("NVIM_LISTEN_ADDRESS")
	if not addr or addr == "" then
		return nil, "NVIM_AGENT_NVIM_ADDR not set"
	end
	return addr
end

local function nvim_eval(expr)
	local addr, err = get_nvim_address()
	if not addr then
		return nil, err
	end

	local cmd = string.format("nvim --server %s --remote-expr %s 2>&1", shell_escape(addr), shell_escape(expr))

	local handle = io.popen(cmd)
	if not handle then
		return nil, "Failed to execute nvim command"
	end

	local result = handle:read("*a")
	local success = handle:close()

	if not success then
		return nil, "nvim command failed: " .. (result or "unknown error")
	end

	return result
end

-- Execute Lua code in Neovim via luaeval.
-- The lua_code must NOT embed arbitrary user content — use write_tmp() for that.
-- Only temp file paths and simple numeric/boolean values are safe to inline.
local function nvim_lua_eval(lua_code)
	local escaped = lua_code:gsub("'", "''")
	return nvim_eval(string.format("luaeval('(function() %s end)()')", escaped))
end

-- Write data to a unique temp file; returns path or nil, err.
local function write_tmp(data)
	_tmp_seq = _tmp_seq + 1
	local path = string.format("/tmp/nvim_agent_%d_%05d.tmp", os.time(), _tmp_seq)
	local f = io.open(path, "w")
	if not f then
		return nil, "Cannot create temp file: " .. path
	end
	f:write(data)
	f:close()
	return path
end

------------------------------------------------------------------------
-- Direct file operations (pure Lua in MCP server — no Neovim RPC,
-- no editor view disruption)
------------------------------------------------------------------------

--- Read a file from disk. start_line/end_line are 1-indexed inclusive.
--- If omitted, reads the entire file.
function M.read_file(filepath, start_line, end_line)
	local f = io.open(filepath, "r")
	if not f then
		return nil, "Cannot open file: " .. filepath
	end

	local all_lines = {}
	for line in f:lines() do
		table.insert(all_lines, line)
	end
	f:close()

	local total = #all_lines
	local s = math.max(1, start_line or 1)
	local e = math.min(total, end_line or total)

	local slice = {}
	for i = s, e do
		table.insert(slice, all_lines[i])
	end

	return { lines = slice, start_line = s, end_line = e, total_lines = total }
end

--- Search for a Lua pattern in a file. Returns matches with line numbers and context.
--- context_lines controls how many surrounding lines are included per match.
function M.search_in_file(filepath, pattern, context_lines)
	local f = io.open(filepath, "r")
	if not f then
		return nil, "Cannot open file: " .. filepath
	end

	local all_lines = {}
	for line in f:lines() do
		table.insert(all_lines, line)
	end
	f:close()

	local total = #all_lines
	local ctx = context_lines or 0
	local matches = {}

	for i, line in ipairs(all_lines) do
		local ok, hit = pcall(string.find, line, pattern)
		if ok and hit then
			local s = math.max(1, i - ctx)
			local e = math.min(total, i + ctx)
			local context = {}
			for j = s, e do
				table.insert(context, { line_number = j, content = all_lines[j] })
			end
			table.insert(matches, {
				line_number = i,
				content = line,
				start_line = s,
				end_line = e,
				context = context,
			})
		end
	end

	return { matches = matches, total_lines = total }
end

------------------------------------------------------------------------
-- Neovim buffer operations (via RPC)
------------------------------------------------------------------------

--- List open file buffers. Special/internal buffers (terminal, NvimTree,
--- dashboard, etc.) are excluded.
function M.list_buffers()
	local lua_code = [[
    local bufs = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        local bt   = vim.api.nvim_buf_get_option(bufnr, 'buftype')
        local ft   = vim.api.nvim_buf_get_option(bufnr, 'filetype')
        if name ~= '' and bt == '' then
          table.insert(bufs, {
            bufnr    = bufnr,
            name     = name,
            modified = vim.api.nvim_buf_get_option(bufnr, 'modified'),
            filetype = ft,
          })
        end
      end
    end
    return vim.json.encode(bufs)
  ]]
	local result, err = nvim_lua_eval(lua_code)
	if not result then
		return nil, err
	end
	local bufs, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	return bufs
end

--- Get the in-memory content of an open buffer by number.
--- May include unsaved changes. For reading files by path use read_file().
function M.get_buffer_content(bufnr)
	local lua_code = string.format(
		[[
    local b = %d
    if not vim.api.nvim_buf_is_valid(b) then
      return vim.json.encode({error = 'Invalid buffer ' .. b})
    end
    return vim.json.encode({lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)})
  ]],
		bufnr
	)
	local result, err = nvim_lua_eval(lua_code)
	if not result then
		return nil, err
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if data.error then
		return nil, data.error
	end
	return data.lines
end

--- Replace the entire in-memory content of a buffer (does NOT save to disk).
--- lines is a table of strings. Prefer edit_and_focus_buffer for most edits.
function M.set_buffer_content(bufnr, lines)
	local tmp, err = write_tmp(json.encode(lines))
	if not tmp then
		return nil, err
	end

	local lua_code = string.format(
		[[
    local b   = %d
    local tmp = '%s'
    if not vim.api.nvim_buf_is_valid(b) then
      os.remove(tmp)
      return vim.json.encode({error = 'Invalid buffer ' .. b})
    end
    local f = io.open(tmp, 'r'); local raw = f:read('*a'); f:close(); os.remove(tmp)
    local lines = vim.json.decode(raw)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return vim.json.encode({success = true})
  ]],
		bufnr,
		tmp
	)

	local result, err2 = nvim_lua_eval(lua_code)
	os.remove(tmp)
	if not result then
		return nil, err2
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if data.error then
		return nil, data.error
	end
	return true
end

--- Load a file into a Neovim buffer without switching windows or moving the cursor.
--- Returns the buffer number. The buffer is added to the buffer list and loaded
--- but not displayed in any window.
function M.open_buffer(filepath)
	local tmp, err = write_tmp(filepath)
	if not tmp then
		return nil, err
	end

	local lua_code = string.format(
		[[
    local tmp = '%s'
    local f = io.open(tmp, 'r'); local fp = f:read('*a'); f:close(); os.remove(tmp)
    local bufnr = vim.fn.bufadd(fp)
    vim.fn.bufload(bufnr)
    return vim.json.encode({bufnr = bufnr})
  ]],
		tmp
	)

	local result, err2 = nvim_lua_eval(lua_code)
	os.remove(tmp)
	if not result then
		return nil, err2
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	return data.bufnr
end

--- Close a buffer by number.
--- force=true discards unsaved changes; force=false (default) returns an
--- error if the buffer has unsaved changes.
function M.close_buffer(bufnr, force)
	local lua_code = string.format(
		[[
    local b     = %d
    local force = %s
    if not vim.api.nvim_buf_is_valid(b) then
      return vim.json.encode({error = 'Invalid buffer ' .. b})
    end
    local ok, err = pcall(vim.api.nvim_buf_delete, b, {force = force})
    if not ok then return vim.json.encode({error = tostring(err)}) end
    return vim.json.encode({success = true})
  ]],
		bufnr,
		force and "true" or "false"
	)

	local result, err = nvim_lua_eval(lua_code)
	if not result then
		return nil, err
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if data.error then
		return nil, data.error
	end
	return true
end

--- Execute a Neovim ex command and return its captured output.
function M.execute_command(cmd)
	local tmp, err = write_tmp(cmd)
	if not tmp then
		return nil, err
	end

	local lua_code = string.format(
		[[
    local tmp = '%s'
    local f = io.open(tmp, 'r'); local cmd = f:read('*a'); f:close(); os.remove(tmp)
    local ok, result = pcall(vim.fn.execute, cmd)
    if not ok then return vim.json.encode({error = tostring(result)}) end
    return vim.json.encode({output = result or ''})
  ]],
		tmp
	)

	local result, err2 = nvim_lua_eval(lua_code)
	os.remove(tmp)
	if not result then
		return nil, err2
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if data.error then
		return nil, data.error
	end
	return data.output
end

--- Move the cursor in the current window. row is 1-indexed, col is 0-indexed.
function M.set_cursor(row, col)
	local lua_code = string.format(
		[[
    vim.api.nvim_win_set_cursor(0, {%d, %d})
    return vim.json.encode({success = true})
  ]],
		row,
		col
	)
	local result, err = nvim_lua_eval(lua_code)
	if not result then
		return nil, err
	end
	return true
end

--- Get the cursor position in the current window.
function M.get_cursor()
	local lua_code = [[
    local c = vim.api.nvim_win_get_cursor(0)
    return vim.json.encode({row = c[1], col = c[2]})
  ]]
	local result, err = nvim_lua_eval(lua_code)
	if not result then
		return nil, err
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	return data
end

--- Load a file into a Neovim buffer, apply new content, and optionally save.
--- The buffer is loaded silently without switching windows or moving the cursor.
---
--- filepath   : path to the file (created if it doesn't exist)
--- content    : new content as a plain string
--- start_line : 1-indexed first line to replace (nil = start of file)
--- end_line   : 1-indexed last line to replace inclusive (nil = end of file)
---              When both are nil the entire file is replaced.
--- save       : write to disk after editing (default true)
--- cursor_line: optional 1-indexed line to position cursor on after edit
---
--- Content is written to a temp file to avoid all escaping issues.
function M.edit_and_focus_buffer(filepath, content, start_line, end_line, save, cursor_line, review)
	local content_tmp, err = write_tmp(content)
	if not content_tmp then
		return nil, err
	end
	local fp_tmp, err2 = write_tmp(filepath)
	if not fp_tmp then
		os.remove(content_tmp)
		return nil, err2
	end

	local lua_code = string.format(
		[[
    local fp_tmp      = '%s'
    local content_tmp = '%s'
    local start_line  = %s
    local end_line    = %s
    local should_save = %s
    local cursor_line = %s
    local review      = %s

    local ff = io.open(fp_tmp,      'r'); local filepath = ff:read('*a'); ff:close(); os.remove(fp_tmp)
    local cf = io.open(content_tmp, 'r'); local raw      = cf:read('*a'); cf:close(); os.remove(content_tmp)

    -- Split content string into lines (handles \n and \r\n)
    local new_lines = {}
    for line in (raw .. '\n'):gmatch('([^\r\n]*)\r?\n') do
      table.insert(new_lines, line)
    end
    -- Remove trailing empty line artifact from split
    if #new_lines > 0 and new_lines[#new_lines] == '' then
      table.remove(new_lines)
    end

    -- Ensure parent directory exists before loading/writing
    local dir = vim.fn.fnamemodify(filepath, ':h')
    if dir and dir ~= '' then
      vim.fn.mkdir(dir, 'p')
    end

    -- Load the buffer silently without switching any window
    local bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].buflisted = true

    -- Apply content: replace a range or the whole file
    if start_line and end_line then
      vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)
    else
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    end

    if should_save then
      local ok, write_err = pcall(function()
        vim.api.nvim_buf_call(bufnr, function() vim.cmd('write') end)
      end)
      if not ok then
        return vim.json.encode({error = 'write failed: ' .. tostring(write_err)})
      end
    end

    -- Position cursor if requested (only meaningful in review mode)
    if cursor_line and review then
      -- Find a window displaying this buffer, or use nvim_buf_call
      local target_win = nil
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
          target_win = win
          break
        end
      end
      if target_win then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        local safe_line = math.min(cursor_line, line_count)
        vim.api.nvim_win_set_cursor(target_win, {safe_line, 0})
      end
    end

    -- Silent mode (review=false): close the buffer after saving
    if not review then
      vim.bo[bufnr].buflisted = false
      pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
    end

    return vim.json.encode({bufnr = bufnr, closed = not review})
  ]],
		fp_tmp,
		content_tmp,
		start_line and tostring(start_line) or "nil",
		end_line and tostring(end_line) or "nil",
		save ~= false and "true" or "false",
		cursor_line and tostring(cursor_line) or "nil",
		review and "true" or "false"
	)

	local result, err3 = nvim_lua_eval(lua_code)
	-- Clean up in case Neovim side errored before os.remove
	os.remove(content_tmp)
	os.remove(fp_tmp)

	if not result then
		return nil, err3
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if data and data.error then
		return nil, data.error
	end
	return data
end

--- Send text to a named agent's terminal. Used by trigger_agent to wake a peer.
--- The agent_name must match an active session name. Returns true or nil, err.
--- @param agent_name string
--- @param text string  Text to inject (include "\n" to auto-submit)
--- @return boolean|nil, string|nil
function M.trigger_agent(agent_name, text)
	local tmp_name, err1 = write_tmp(agent_name)
	if not tmp_name then
		return nil, err1
	end
	local tmp_text, err2 = write_tmp(text)
	if not tmp_text then
		os.remove(tmp_name)
		return nil, err2
	end

	local lua_code = string.format(
		[[
    local tmp_name = '%s'
    local tmp_text = '%s'
    local fn = io.open(tmp_name, 'r'); local name = fn:read('*a'); fn:close(); os.remove(tmp_name)
    local ft = io.open(tmp_text, 'r'); local text = ft:read('*a'); ft:close(); os.remove(tmp_text)
    local ok, result = pcall(require('nvim-agent.terminal').send_by_name, name, text)
    return vim.json.encode({success = ok, error = ok and nil or tostring(result)})
  ]],
		tmp_name,
		tmp_text
	)

	local result, err3 = nvim_lua_eval(lua_code)
	os.remove(tmp_name)
	os.remove(tmp_text)
	if not result then
		return nil, err3
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if not data.success then
		return nil, data.error
	end
	return true
end

--- Spawn a new workspace agent non-interactively via Neovim RPC.
--- Creates the agent definition dir, writes context files, creates a session,
--- and opens the terminal. Returns true or nil, err.
--- @param agent_name string
--- @param system_prompt string  System prompt content for the agent
--- @param role string           Role description for peer discovery
--- @param user_notes string     User notes content
--- @return boolean|nil, string|nil
function M.spawn_agent(agent_name, system_prompt, role, user_notes)
	local tmp_name, err1 = write_tmp(agent_name)
	if not tmp_name then
		return nil, err1
	end
	local tmp_prompt, err2 = write_tmp(system_prompt)
	if not tmp_prompt then
		os.remove(tmp_name)
		return nil, err2
	end
	local tmp_role, err3 = write_tmp(role)
	if not tmp_role then
		os.remove(tmp_name)
		os.remove(tmp_prompt)
		return nil, err3
	end
	local tmp_notes, err4 = write_tmp(user_notes)
	if not tmp_notes then
		os.remove(tmp_name)
		os.remove(tmp_prompt)
		os.remove(tmp_role)
		return nil, err4
	end

	local lua_code = string.format(
		[[
    local tmp_name = '%s'
    local tmp_prompt = '%s'
    local tmp_role = '%s'
    local tmp_notes = '%s'
    local function read_tmp(p) local f = io.open(p, 'r'); local c = f:read('*a'); f:close(); os.remove(p); return c end
    local name = read_tmp(tmp_name)
    local prompt = read_tmp(tmp_prompt)
    local role = read_tmp(tmp_role)
    local notes = read_tmp(tmp_notes)
    local ok, result = pcall(function()
      return require('nvim-agent').spawn_agent_noninteractive(name, prompt, role, notes)
    end)
    if not ok then
      return vim.json.encode({success = false, error = tostring(result)})
    end
    return vim.json.encode(result)
  ]],
		tmp_name,
		tmp_prompt,
		tmp_role,
		tmp_notes
	)

	local result, rpc_err = nvim_lua_eval(lua_code)
	os.remove(tmp_name)
	os.remove(tmp_prompt)
	os.remove(tmp_role)
	os.remove(tmp_notes)
	if not result then
		return nil, rpc_err
	end
	local data, derr = decode_response(result)
	if derr then
		return nil, derr
	end
	if not data.success then
		return nil, data.error
	end
	return true
end

return M
