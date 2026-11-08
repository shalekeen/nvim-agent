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
	return string.format("[Agent-%s: %s]", sess.name, sess.agent or "agent")
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

--- Build an N-cell grid of windows (rows × cols) in a fresh tab and return
--- the windows in row-major order. Surplus cells are closed.
--- @param n integer
--- @param cols integer
--- @return integer[] wins
local function build_grid(n, cols)
	local rows = math.ceil(n / cols)
	vim.cmd("tabnew")
	local row_wins = { vim.api.nvim_get_current_win() }
	for r = 2, rows do
		vim.api.nvim_set_current_win(row_wins[r - 1])
		vim.cmd("belowright split")
		row_wins[r] = vim.api.nvim_get_current_win()
	end
	local wins = {}
	for r = 1, rows do
		local row = { row_wins[r] }
		for c = 2, cols do
			vim.api.nvim_set_current_win(row[c - 1])
			vim.cmd("belowright vsplit")
			row[c] = vim.api.nvim_get_current_win()
		end
		for c = 1, cols do
			table.insert(wins, row[c])
		end
	end
	vim.cmd("wincmd =")
	for i = #wins, n + 1, -1 do
		if vim.api.nvim_win_is_valid(wins[i]) then
			vim.api.nvim_win_close(wins[i], true)
		end
		wins[i] = nil
	end
	return wins
end

--- Spawn the adapter CLI for `sess` inside the given window. Creates the
--- terminal buffer, names it, pins it in barbar, runs adapter buffer-keymap
--- setup, and scrolls to bottom. Used by M.open (single session, and
--- relaunch of an exited session) and M.open_grid (per cell).
local function launch_session_in_window(sess, win, adapter)
	require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)

	if adapter.setup_session_mcp then
		adapter:setup_session_mcp(sess)
	end

	sess.bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(win, sess.bufnr)
	sess.winnr = win
	vim.api.nvim_set_current_win(win)

	local cwd = vim.fn.getcwd()
	sess.jobid = vim.fn.termopen(adapter:get_cmd(sess), {
		env = {
			NVIM_AGENT_ACTIVE_DIR = sess.active_dir,
			NVIM_AGENT_PROCESS_DIR = sess.process_dir,
			NVIM_AGENT_CWD = cwd,
			NVIM_AGENT_BASE_DIR = require("nvim-agent.config").get().base_dir,
			-- Per-instance identity. The hook script reads peer state from
			-- NVIM_AGENT_RUNTIME_DIR so each Neovim instance's agents only
			-- ever see their own siblings.
			NVIM_AGENT_INSTANCE_ID = require("nvim-agent.session").instance_id,
			NVIM_AGENT_RUNTIME_DIR = require("nvim-agent.workspace").instance_runtime_dir(cwd),
		},
		on_exit = function(_, code, _)
			vim.schedule(function()
				-- Stale callback guard: if this session was closed (and perhaps
				-- recreated under the same name, hence the same id) before the
				-- old job's exit arrived, do nothing — otherwise we would mark
				-- the NEW session exited and strip its status file.
				local sm = require("nvim-agent.session")
				if sm.get(sess.id) ~= sess then
					return
				end
				-- The CLI ended on its own (user typed /exit, crash, ...).
				-- The session stays a workspace member but is marked exited
				-- and its status file is removed so peers stop delegating to
				-- it. It can be relaunched with :NvimAgent agent restart or
				-- by a peer calling spawn_agent with the same name.
				sm.mark_exited(sess.id, code)
				if sess.stop_requested then
					sess.stop_requested = nil
					return
				end
				local level = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
				vim.notify(
					string.format(
						"nvim-agent: agent '%s' exited (code %d). Relaunch with :NvimAgent agent restart %s",
						sess.name,
						code,
						sess.name
					),
					level
				)
			end)
		end,
	})
	sess.state = "running"
	sess.exit_code = nil

	vim.api.nvim_buf_set_name(sess.bufnr, buf_name(sess))
	vim.bo[sess.bufnr].filetype = "nvim-agent"
	pin_agent_buffer(sess.bufnr)

	if adapter.setup_buffer_keymaps then
		adapter:setup_buffer_keymaps(sess.bufnr)
	end

	scroll_to_bottom(sess.bufnr, win)
end

--- Open (or focus) a session's terminal. If the session's CLI has exited,
--- this relaunches it into the same active_dir in a fresh terminal buffer.
--- @param session_id string|nil  defaults to the current session
function M.open(session_id)
	local sess = get_session(session_id)
	if not sess then
		vim.notify("nvim-agent: no session available. Load a workspace first.", vim.log.levels.ERROR)
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

	local session_mod = require("nvim-agent.session")
	require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)

	if is_buf_valid(sess) and session_mod.is_running(sess) then
		if is_win_valid(sess) then
			vim.api.nvim_set_current_win(sess.winnr)
		else
			sess.winnr = create_split()
			vim.api.nvim_win_set_buf(sess.winnr, sess.bufnr)
		end
		vim.cmd("startinsert")
		return
	end

	-- Not running: either never launched, or exited. Launch afresh, reusing
	-- the window if it is still open. The dead terminal buffer must go
	-- BEFORE the new one is named (it still owns the "[Agent-…]" name), but
	-- deleting the only buffer in a window closes the window — so park a
	-- throwaway scratch buffer in the window first.
	local old_buf = is_buf_valid(sess) and sess.bufnr or nil
	sess.bufnr = nil
	if old_buf then
		if is_win_valid(sess) then
			local scratch = vim.api.nvim_create_buf(false, true)
			vim.bo[scratch].bufhidden = "wipe"
			vim.api.nvim_win_set_buf(sess.winnr, scratch)
		end
		pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
	end
	local win = is_win_valid(sess) and sess.winnr or create_split()
	launch_session_in_window(sess, win, adapter)
	vim.cmd("startinsert")
end

--- Open multiple sessions in a Y×N grid in a fresh tab.
--- @param session_ids string[]
--- @param cols number|nil  default 4
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

	local wins = build_grid(#sessions, cols)
	for i, sess in ipairs(sessions) do
		launch_session_in_window(sess, wins[i], adapter)
	end

	if sessions[1] and sessions[1].winnr and vim.api.nvim_win_is_valid(sessions[1].winnr) then
		vim.api.nvim_set_current_win(sessions[1].winnr)
	end
end

--- Arrange every RUNNING session's existing terminal buffer in a grid in a
--- fresh tab. Unlike open_grid this launches nothing; exited members are
--- skipped (relaunch them with restart).
--- @param cols number|nil
--- @return integer  number of sessions shown
function M.show_all(cols)
	local session_mod = require("nvim-agent.session")
	local shown = {}
	for _, sess in ipairs(session_mod.list()) do
		if session_mod.is_running(sess) and is_buf_valid(sess) then
			table.insert(shown, sess)
		end
	end
	if #shown == 0 then
		vim.notify("nvim-agent: no running agents to show", vim.log.levels.INFO)
		return 0
	end
	local wins = build_grid(#shown, cols or 4)
	for i, sess in ipairs(shown) do
		vim.api.nvim_win_set_buf(wins[i], sess.bufnr)
		sess.winnr = wins[i]
	end
	vim.api.nvim_set_current_win(wins[1])
	return #shown
end

--- Hide every window currently showing an agent terminal. Processes keep
--- running. A tab that held only agent windows is closed.
--- @return integer  number of windows hidden
function M.hide_all()
	local session_mod = require("nvim-agent.session")
	local hidden = 0
	for _, sess in ipairs(session_mod.list()) do
		if is_win_valid(sess) then
			local win = sess.winnr
			sess.winnr = nil
			if not pcall(vim.api.nvim_win_close, win, true) then
				-- Last window in its tab: close the tab if there is another one.
				if #vim.api.nvim_list_tabpages() > 1 then
					local tab = vim.api.nvim_win_get_tabpage(win)
					pcall(vim.api.nvim_set_current_tabpage, tab)
					pcall(vim.cmd, "tabclose")
				else
					-- Only window in the only tab: swap in an empty buffer instead.
					local scratch = vim.api.nvim_create_buf(true, false)
					vim.api.nvim_win_set_buf(win, scratch)
				end
			end
			hidden = hidden + 1
		end
	end
	return hidden
end

--- Stop a session's CLI process. The on_exit handler marks it exited; the
--- usual "agent exited" warning is suppressed because the user asked.
function M.stop(session_id)
	local sess = get_session(session_id)
	if not sess or not sess.jobid then
		return
	end
	sess.stop_requested = true
	vim.fn.jobstop(sess.jobid)
end

--- Hide a session's window. The process keeps running.
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

--- Type `text` into the agent terminal and submit it as if the user pressed
--- Enter.
---
--- Why the split-and-defer pattern below:
--- Claude Code (and other React/Ink-style TUIs) read raw input from a PTY
--- in raw mode. When we send `text .. "\r"` as a single `nvim_chan_send`
--- call, all bytes arrive at the PTY in one read. The TUI's input loop
--- sees a single chunk and treats the trailing `\r` as a newline embedded
--- in the typed text — not as a discrete "Enter" keypress that submits.
--- Symptom: the wakeup message appears in the input box but never sends.
---
--- Splitting into two writes with a small gap (the deferred `\r`) makes the
--- TUI register them as two separate input events: first "user typed
--- <text>", then "user pressed Enter". 100 ms is imperceptible to a human
--- but reliably long enough for the TUI's input handler to land between
--- the two.
---
--- We also strip any trailing CR/LF from the incoming text so callers can
--- still pass `"...\r"` (the legacy convention) without us double-firing
--- Enter.
function M.send(session_id, text)
	local sess = get_session(session_id)
	if not sess then
		return
	end
	if not sess.jobid then
		vim.notify(string.format("nvim-agent: agent '%s' is not running", sess.name), vim.log.levels.WARN)
		return
	end
	text = (text or ""):gsub("[\r\n]+$", "")
	if text ~= "" then
		vim.api.nvim_chan_send(sess.jobid, text)
	end
	vim.defer_fn(function()
		if sess.jobid then
			vim.api.nvim_chan_send(sess.jobid, "\r")
		end
	end, 100)
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

--- Find a session by name and submit text to its terminal. Used by the MCP
--- trigger_agent tool via Neovim RPC. See M.send for why Enter is deferred.
--- @param agent_name string  Session name
--- @param text string
--- @return boolean
function M.send_by_name(agent_name, text)
	local sess = require("nvim-agent.session").get_by_name(agent_name)
	if not sess or not sess.jobid then
		return false
	end
	text = (text or ""):gsub("[\r\n]+$", "")
	if text ~= "" then
		vim.api.nvim_chan_send(sess.jobid, text)
	end
	vim.defer_fn(function()
		if sess.jobid then
			vim.api.nvim_chan_send(sess.jobid, "\r")
		end
	end, 100)
	return true
end

--- Stop the job and delete the buffer. Does not touch the registry.
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
