-- Keeps the user's view where it is while an agent acts inside Neovim.
--
-- Runs INSIDE the parent Neovim (called from nvim_rpc's remote-expr Lua, like
-- buffer_ops). An agent's MCP call lands while the user may be typing into
-- another agent's terminal; nothing an agent does may move them. Two jobs:
--
--   * run(fn): execute fn, then put back the current window, the buffer that
--     window showed, its cursor, and terminal mode if the user was in it.
--     Used around execute_command, whose ex commands (:edit, :buffer,
--     :split, :copen, ...) would otherwise retarget the user's window.
--   * file_window(filepath): the window an agent's cursor operation should
--     act on: the one showing `filepath`, else the window of the file the
--     user was last editing, else any file window. Never a terminal.
local M = {}

local function is_file_buf(buf)
	return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == ""
end

--- @return table snapshot
function M.snapshot()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	return {
		win = win,
		buf = buf,
		cursor = vim.api.nvim_win_get_cursor(win),
		terminal_mode = vim.api.nvim_get_mode().mode:sub(1, 1) == "t",
		tab = vim.api.nvim_get_current_tabpage(),
	}
end

--- Restore a snapshot. Returns a list of what had to be put back (empty when
--- nothing moved), for the tool result.
--- @param snap table
--- @return string[] restored
function M.restore(snap)
	local restored = {}
	if not vim.api.nvim_win_is_valid(snap.win) then
		return { "original window was closed; focus left where the command put it" }
	end
	if vim.api.nvim_get_current_tabpage() ~= snap.tab and vim.api.nvim_tabpage_is_valid(snap.tab) then
		vim.api.nvim_set_current_tabpage(snap.tab)
		table.insert(restored, "tab")
	end
	if vim.api.nvim_get_current_win() ~= snap.win then
		vim.api.nvim_set_current_win(snap.win)
		table.insert(restored, "window focus")
	end
	if vim.api.nvim_win_get_buf(snap.win) ~= snap.buf and vim.api.nvim_buf_is_valid(snap.buf) then
		vim.api.nvim_win_set_buf(snap.win, snap.buf)
		table.insert(restored, "buffer shown in the user's window")
	end
	if vim.api.nvim_win_get_buf(snap.win) == snap.buf then
		local ok = pcall(vim.api.nvim_win_set_cursor, snap.win, snap.cursor)
		if ok and #restored > 0 then
			table.insert(restored, "cursor")
		end
	end
	if snap.terminal_mode and #restored > 0 and vim.bo[snap.buf].buftype == "terminal" then
		-- The command kicked the user out of terminal mode; re-enter once
		-- the RPC callback has returned.
		vim.schedule(function()
			if vim.api.nvim_get_current_buf() == snap.buf and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "t" then
				vim.cmd("startinsert")
			end
		end)
		table.insert(restored, "terminal mode")
	end
	return restored
end

--- Run fn with the user's view protected.
--- @param fn fun(): any
--- @return boolean ok, any result_or_error, string[] restored
function M.run(fn)
	local snap = M.snapshot()
	local ok, result = pcall(fn)
	local restored = M.restore(snap)
	return ok, result, restored
end

--- The window an agent cursor operation should act on. Never a terminal.
--- @param filepath string|nil
--- @return integer|nil win, string|nil err
function M.file_window(filepath)
	if filepath and filepath ~= "" then
		local abs = vim.fn.fnamemodify(filepath, ":p")
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local b = vim.api.nvim_win_get_buf(w)
			if is_file_buf(b) and vim.api.nvim_buf_get_name(b) == abs then
				return w
			end
		end
		return nil, "'" .. filepath .. "' is not shown in any window of the current tab"
	end
	local cur = vim.api.nvim_get_current_win()
	if is_file_buf(vim.api.nvim_win_get_buf(cur)) then
		return cur
	end
	local ok, eph = pcall(require, "nvim-agent.context.ephemeral")
	local last = ok and eph.last_file or nil
	if last and vim.api.nvim_buf_is_valid(last.bufnr) then
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if vim.api.nvim_win_get_buf(w) == last.bufnr then
				return w
			end
		end
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if is_file_buf(vim.api.nvim_win_get_buf(w)) and vim.api.nvim_win_get_config(w).relative == "" then
			return w
		end
	end
	return nil, "no file window in the current tab (the user is in an agent terminal); pass filepath or skip the cursor move"
end

return M
