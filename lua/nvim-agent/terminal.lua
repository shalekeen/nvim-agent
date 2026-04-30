local M = {}

local config = require("nvim-agent.config")

local function get_session(session_id)
	local session_mod = require("nvim-agent.session")
	if session_id then
		return session_mod.get(session_id)
	end
	return session_mod.get_current()
end

local function is_buf_valid(sess)
	return sess.bufnr and vim.api.nvim_buf_is_valid(sess.bufnr) and vim.api.nvim_buf_is_loaded(sess.bufnr)
end

local function is_win_valid(sess)
	return sess.winnr and vim.api.nvim_win_is_valid(sess.winnr)
end

local function buf_name(sess)
	return string.format("[Agent-%s: %s]", sess.name, sess.flavor or "agent")
end

--- Pin an agent buffer to the left in barbar using internal state API.
--- Uses barbar.state directly so we can pin by bufnr without switching windows.
--- Safe to call multiple times and during concurrent agent launches.
local function pin_agent_buffer(bufnr)
	vim.defer_fn(function()
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local ok, barbar_state = pcall(require, "barbar.state")
		if ok and barbar_state then
			local data = barbar_state.get_buffer_data(bufnr)
			if not data.pinned then
				data.pinned = true
				barbar_state.sort_pins_to_left()
			end
			-- Always redraw with update_names=true so barbar picks up
			-- buffer names set after the buffer was first listed.
			local ok2, render = pcall(require, "barbar.ui.render")
			if ok2 and render then
				pcall(render.update, true)
			end
		end
	end, 150)
end

local function create_split()
	local cfg = config.get()
	local total
	if cfg.terminal.split_direction == "vertical" then
		total = vim.o.columns
		local size = math.floor(total * cfg.terminal.split_size)
		vim.cmd("botright " .. size .. "vsplit")
	else
		total = vim.o.lines
		local size = math.floor(total * cfg.terminal.split_size)
		vim.cmd("botright " .. size .. "split")
	end
	return vim.api.nvim_get_current_win()
end

--- Scroll a terminal buffer to the bottom after a delay.
--- Waits for the CLI tool to load before jumping to the last line.
--- @param bufnr number  Buffer number
--- @param winnr number  Window number
--- @param delay_ms number|nil  Delay in ms (default 5000)
local function scroll_to_bottom(bufnr, winnr, delay_ms)
	vim.defer_fn(function()
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		if not winnr or not vim.api.nvim_win_is_valid(winnr) then
			return
		end
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		vim.api.nvim_win_set_cursor(winnr, { line_count, 0 })
	end, delay_ms or 5000)
end

--- Spawn the adapter CLI for `sess` inside the given window. Creates the
--- terminal buffer, sets the buffer name and filetype, pins it in barbar, runs
--- adapter buffer-keymap setup, and scrolls to bottom. Used by both M.open's
--- single-session path and M.open_grid's per-cell path.
local function launch_session_in_window(sess, win, adapter)
	require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)

	if adapter.setup_session_mcp then
		adapter:setup_session_mcp(sess)
	end

	sess.bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(win, sess.bufnr)
	sess.winnr = win
	vim.api.nvim_set_current_win(win)

	sess.jobid = vim.fn.termopen(adapter:get_cmd(sess), {
		env = {
			NVIM_AGENT_ACTIVE_DIR = sess.active_dir,
			NVIM_AGENT_PROCESS_DIR = sess.process_dir,
			NVIM_AGENT_CWD = vim.fn.getcwd(),
			NVIM_AGENT_BASE_DIR = require("nvim-agent.config").get().base_dir,
		},
		on_exit = function(_, code, _)
			vim.schedule(function()
				if code ~= 0 then
					vim.notify(
						string.format("nvim-agent: session '%s' exited with code %d", sess.name, code),
						vim.log.levels.WARN
					)
				end
				sess.jobid = nil
			end)
		end,
	})

	vim.api.nvim_buf_set_name(sess.bufnr, buf_name(sess))
	vim.bo[sess.bufnr].filetype = "nvim-agent"
	pin_agent_buffer(sess.bufnr)

	if adapter.setup_buffer_keymaps then
		adapter:setup_buffer_keymaps(sess.bufnr)
	end

	scroll_to_bottom(sess.bufnr, win)
end

function M.open(session_id)
	local sess = get_session(session_id)
	if not sess then
		vim.notify("nvim-agent: no session available. Select a flavor first.", vim.log.levels.ERROR)
		return
	end

	local adapter = require("nvim-agent.adapter").get_active()
	if not adapter then
		vim.notify(
			'nvim-agent: no adapter configured. Set `adapter` in your plugin opts (e.g., adapter = "claude_code").',
			vim.log.levels.ERROR
		)
		return
	end

	-- Write context before opening
	require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)

	if is_buf_valid(sess) then
		if is_win_valid(sess) then
			-- Already open, focus it
			vim.api.nvim_set_current_win(sess.winnr)
		else
			-- Buffer exists but window closed, reopen in split
			sess.winnr = create_split()
			vim.api.nvim_win_set_buf(sess.winnr, sess.bufnr)
		end
		-- Refresh context on re-focus too, for consistency with the BufEnter autocmd.
		require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)
		vim.cmd("startinsert")
		return
	end

	launch_session_in_window(sess, create_split(), adapter)
	vim.cmd("startinsert")
end

--- Open multiple sessions in a Y×4 grid layout.
--- Creates a grid of terminal windows: 4 columns, as many rows as needed.
--- Each session gets its own window with a terminal buffer.
--- @param session_ids string[]  List of session IDs to open in the grid
--- @param cols number|nil       Number of columns (default 4)
function M.open_grid(session_ids, cols)
	cols = cols or 4
	local sessions = {}
	local session_mod = require("nvim-agent.session")
	for _, id in ipairs(session_ids) do
		local sess = session_mod.get(id)
		if sess then
			table.insert(sessions, sess)
		end
	end
	if #sessions == 0 then
		return
	end

	local adapter = require("nvim-agent.adapter").get_active()
	if not adapter then
		vim.notify("nvim-agent: no adapter configured", vim.log.levels.ERROR)
		return
	end

	local rows = math.ceil(#sessions / cols)

	-- Create a fresh empty tab so the grid doesn't interfere with existing layout
	vim.cmd("tabnew")
	local first_win = vim.api.nvim_get_current_win()

	-- Phase 1: Create all rows by splitting the initial full-width window
	-- horizontally. Each split divides the remaining vertical space.
	local row_wins = { first_win }
	for r = 2, rows do
		vim.api.nvim_set_current_win(row_wins[r - 1])
		vim.cmd("belowright split")
		row_wins[r] = vim.api.nvim_get_current_win()
	end

	-- Phase 2: Split each row into columns.
	-- Now each row_wins[r] is a full-width window; vsplitting it produces even columns.
	local grid_wins = {}
	for r = 1, rows do
		grid_wins[r] = { row_wins[r] }
		for c = 2, cols do
			vim.api.nvim_set_current_win(grid_wins[r][c - 1])
			vim.cmd("belowright vsplit")
			grid_wins[r][c] = vim.api.nvim_get_current_win()
		end
	end

	-- Equalize all windows
	vim.cmd("wincmd =")

	-- Now place a terminal in each grid cell
	local idx = 0
	for r = 1, rows do
		for c = 1, cols do
			idx = idx + 1
			if idx > #sessions then
				-- No more sessions — close the extra window
				if grid_wins[r] and grid_wins[r][c] and vim.api.nvim_win_is_valid(grid_wins[r][c]) then
					vim.api.nvim_win_close(grid_wins[r][c], true)
				end
			else
				launch_session_in_window(sessions[idx], grid_wins[r][c], adapter)
			end
		end
	end

	-- Focus the first agent's window
	if sessions[1] and sessions[1].winnr and vim.api.nvim_win_is_valid(sessions[1].winnr) then
		vim.api.nvim_set_current_win(sessions[1].winnr)
	end
end

function M.close(session_id)
	local sess = get_session(session_id)
	if not sess then
		return
	end
	if is_win_valid(sess) then
		vim.api.nvim_win_close(sess.winnr, true)
		sess.winnr = nil
	end
end

function M.toggle(session_id)
	local sess = get_session(session_id)
	if not sess then
		return
	end
	if is_win_valid(sess) then
		M.close(sess.id)
	else
		M.open(sess.id)
	end
end

function M.send(session_id, text)
	local sess = get_session(session_id)
	if not sess then
		return
	end
	if sess.jobid then
		vim.api.nvim_chan_send(sess.jobid, text)
	else
		vim.notify(
			string.format("nvim-agent: no agent running for session %d", sess.instance_num or 0),
			vim.log.levels.WARN
		)
	end
end

function M.is_open(session_id)
	local sess = get_session(session_id)
	if not sess then
		return false
	end
	return is_win_valid(sess)
end

function M.get_bufnr(session_id)
	local sess = get_session(session_id)
	if not sess then
		return nil
	end
	return sess.bufnr
end

--- Find a session by agent name and send text to its terminal.
--- Used by the MCP trigger_agent tool via Neovim RPC.
--- @param agent_name string  Session name (e.g. "researcher", "pm")
--- @param text string        Text to inject; include "\n" to auto-submit
--- @return boolean
function M.send_by_name(agent_name, text)
	local sess = require("nvim-agent.session").get_by_name(agent_name)
	if not sess or not sess.jobid then
		return false
	end
	vim.api.nvim_chan_send(sess.jobid, text)
	return true
end

function M.cleanup(session_id)
	local sess = get_session(session_id)
	if not sess then
		return
	end
	if sess.jobid then
		vim.fn.jobstop(sess.jobid)
		sess.jobid = nil
	end
	if is_buf_valid(sess) then
		vim.api.nvim_buf_delete(sess.bufnr, { force = true })
	end
	sess.bufnr = nil
	sess.winnr = nil
end

return M
