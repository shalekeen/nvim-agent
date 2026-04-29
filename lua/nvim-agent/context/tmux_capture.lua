local M = {}

local config = require("nvim-agent.config")

--- Check if Neovim is running inside a tmux session.
--- @return boolean
function M.is_tmux()
	local tmux = os.getenv("TMUX")
	return tmux ~= nil and tmux ~= ""
end

--- Return the pane ID of the current Neovim pane (used to exclude it from the picker).
--- @return string|nil
function M.current_pane_id()
	return os.getenv("TMUX_PANE")
end

--- List all tmux panes, excluding the one running Neovim.
--- @return table[] Array of pane info tables with pane_id, display, session_name, etc.
function M.list_panes()
	local format =
		"#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_current_command}"
	local cmd = string.format("tmux list-panes -a -F %s 2>/dev/null", vim.fn.shellescape(format))
	local ok, raw = pcall(vim.fn.system, cmd)
	if not ok or vim.v.shell_error ~= 0 or not raw then
		return {}
	end

	local current = M.current_pane_id()
	local panes = {}

	for line in raw:gmatch("[^\n]+") do
		local pane_id, session_name, window_index, window_name, pane_index, current_command =
			line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]*)$")
		if pane_id and pane_id ~= current then
			local display = string.format("%s:%s.%s (%s)", session_name, window_index, pane_index, current_command)
			table.insert(panes, {
				pane_id = pane_id,
				session_name = session_name,
				window_index = window_index,
				window_name = window_name,
				pane_index = pane_index,
				current_command = current_command,
				display = display,
			})
		end
	end

	return panes
end

--- Capture the content of a tmux pane.
--- @param pane_id string  Tmux pane target (e.g., "%3")
--- @param lines number|nil  Number of scrollback lines to capture; nil for visible only
--- @return string|nil content, string|nil error
function M.capture_pane(pane_id, lines)
	local cmd
	if lines and lines > 0 then
		cmd = string.format("tmux capture-pane -p -t %s -S -%d 2>/dev/null", vim.fn.shellescape(pane_id), lines)
	else
		cmd = string.format("tmux capture-pane -p -t %s 2>/dev/null", vim.fn.shellescape(pane_id))
	end

	local ok, raw = pcall(vim.fn.system, cmd)
	if not ok or vim.v.shell_error ~= 0 then
		return nil, "tmux capture-pane failed"
	end

	-- Trim trailing blank lines
	local content = raw:gsub("%s+$", "")
	return content
end

--- Read the captures file from disk.
--- @param process_dir string
--- @return table  { captures = { ... } }
function M.load(process_dir)
	local cfg = config.get()
	local path = process_dir .. "/" .. cfg.context_files.tmux_captures
	local f = io.open(path, "r")
	if not f then
		return { captures = {} }
	end
	local raw = f:read("*a")
	f:close()
	if not raw or raw == "" then
		return { captures = {} }
	end
	local ok, data = pcall(vim.json.decode, raw)
	if ok and type(data) == "table" then
		data.captures = data.captures or {}
		return data
	end
	return { captures = {} }
end

--- Write the captures data to disk.
--- @param data table  { captures = { ... } }
--- @param process_dir string
function M.save(data, process_dir)
	local cfg = config.get()
	local path = process_dir .. "/" .. cfg.context_files.tmux_captures
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return
	end
	f:write(vim.json.encode(data))
	f:close()
end

--- Capture a pane and add it to the captures file.
--- Replaces any existing capture for the same pane_id.
--- @param process_dir string
--- @param pane_id string
--- @param label string  Display label for this pane
--- @param lines number|nil  Scrollback lines; nil for visible only
--- @return table|nil capture_entry, string|nil error
function M.add_capture(process_dir, pane_id, label, lines)
	local content, err = M.capture_pane(pane_id, lines)
	if not content then
		return nil, err
	end

	local line_count = 0
	for _ in content:gmatch("[^\n]*") do
		line_count = line_count + 1
	end

	local entry = {
		pane_id = pane_id,
		label = label,
		captured_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		line_count = line_count,
		content = content,
	}

	local data = M.load(process_dir)

	-- Replace existing capture for the same pane, or append
	local replaced = false
	for i, cap in ipairs(data.captures) do
		if cap.pane_id == pane_id then
			data.captures[i] = entry
			replaced = true
			break
		end
	end
	if not replaced then
		table.insert(data.captures, entry)
	end

	M.save(data, process_dir)
	return entry
end

--- Clear all captures.
--- @param process_dir string
function M.clear(process_dir)
	M.save({ captures = {} }, process_dir)
end

return M
