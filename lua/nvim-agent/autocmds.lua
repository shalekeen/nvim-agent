local M = {}

local uv = vim.uv or vim.loop

--- Timer granularity. Per-agent intervals are multiples of this in effect;
--- agent.MIN_WAKEUP_INTERVAL keeps intervals at or above it.
M.TICK_MS = 5000

--- Decide, for one session at time `now` (ms, monotonic), whether to nudge
--- it. Returns a short reason string, for tests and debugging:
---   "disabled"  inbox_wakeups = false
---   "inactive"  no running terminal
---   "baseline"  first observation; records the current changedtick
---   "waiting"   its interval has not elapsed since the last evaluation
---   "active"    terminal produced output during the interval
---   "quiet"     idle but nothing pending
---   "nudged"    idle with a pending trigger or new mail → wake sent
--- @param sess table
--- @param now number
--- @return string
function M.evaluate_wakeup(sess, now)
	local session_mod = require("nvim-agent.session")
	local state = M._wake_state

	local bufnr = sess.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not sess.jobid then
		state[sess.id] = nil
		return "inactive"
	end

	local cfg = session_mod.config(sess)
	if not cfg.inbox_wakeups then
		state[sess.id] = nil
		return "disabled"
	end

	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local st = state[sess.id]
	if not st then
		state[sess.id] = { tick = tick, at = now, handled_msg_mtime = nil }
		return "baseline"
	end
	if now - st.at < cfg.inbox_wakeup_interval * 1000 then
		return "waiting"
	end

	local prev_tick = st.tick
	st.tick = tick
	st.at = now
	if tick ~= prev_tick then
		return "active"
	end

	-- Scoped to this Neovim instance's runtime tree for the project the
	-- session was launched in (not the current :cd): a trigger written for
	-- "main" in another instance must not wake ours.
	local instance_dir = require("nvim-agent.workspace").instance_runtime_dir(sess.cwd or vim.fn.getcwd())
	local trigger_file = instance_dir .. "/triggers/" .. sess.name .. ".md"
	local msg_file = instance_dir .. "/messages/" .. sess.name .. ".md"
	local has_trigger = vim.fn.getfsize(trigger_file) > 0

	local msg_stat = uv.fs_stat(msg_file)
	local msg_mtime = nil
	if msg_stat and (msg_stat.size or 0) > 0 and msg_stat.mtime then
		msg_mtime = (msg_stat.mtime.sec or 0) * 1e9 + (msg_stat.mtime.nsec or 0)
	end
	local has_new_messages = msg_mtime ~= nil and msg_mtime ~= st.handled_msg_mtime

	if not has_trigger and not has_new_messages then
		return "quiet"
	end

	require("nvim-agent.terminal").send(sess.id, "You have pending messages or tasks. Please continue your work.\r")
	if has_trigger then
		-- Lock the trigger file: an MCP-side trigger_agent may be appending
		-- right now. Short retry budget so the timer never stalls; on lock
		-- failure we still truncate (the agent still has the mail itself).
		local ok_lock, filelock = pcall(require, "nvim-agent.mcp.filelock")
		local got = ok_lock and filelock.acquire(trigger_file, { agent = "nvim-autocmd", retries = 1, delay_ms = 50 })
		local f = io.open(trigger_file, "w")
		if f then
			f:close()
		end
		if got then
			filelock.release(trigger_file)
		end
	end
	if has_new_messages then
		st.handled_msg_mtime = msg_mtime
	end
	return "nudged"
end

function M.register()
	-- Idempotent: if register() is invoked twice (e.g. plugin reload), the old
	-- timers must be stopped before we allocate new ones.
	for _, timer_key in ipairs({ "_continuation_timer", "_msg_timer" }) do
		local t = M[timer_key]
		if t then
			pcall(t.stop, t)
			pcall(t.close, t)
			M[timer_key] = nil
		end
	end
	M._wake_state = nil

	local group = vim.api.nvim_create_augroup("NvimAgent", { clear = true })
	local config = require("nvim-agent.config")

	-- Refresh ephemeral context when entering an agent terminal buffer and
	-- mark that session current.
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function(ev)
			if vim.bo[ev.buf].filetype == "nvim-agent" then
				local session_mod = require("nvim-agent.session")
				local sess = session_mod.find_by_bufnr(ev.buf)
				if sess then
					session_mod.set_current(sess.id)
				end

				if config.get().auto_write_context and sess then
					vim.schedule(function()
						require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)
					end)
				end

				vim.schedule(function()
					local adapter = require("nvim-agent.adapter").get_active()
					if adapter and adapter.on_enter then
						adapter:on_enter(ev.buf)
					end
				end)
			end
		end,
		desc = "nvim-agent: write context on agent buffer enter",
	})

	-- Warn when quitting with running agents.
	vim.api.nvim_create_autocmd("QuitPre", {
		group = group,
		callback = function()
			local ok, session_mod = pcall(require, "nvim-agent.session")
			if not ok then
				return
			end
			local running = {}
			for _, sess in ipairs(session_mod.list()) do
				if sess.jobid then
					table.insert(running, sess.name)
				end
			end
			if #running > 0 then
				vim.api.nvim_echo({
					{ "nvim-agent: ", "WarningMsg" },
					{ #running .. " agent(s) still running: " .. table.concat(running, ", "), "WarningMsg" },
					{ "  (use <leader>aQ for graceful quit)", "Comment" },
				}, true, {})
			end
		end,
		desc = "nvim-agent: warn on quit with running agents",
	})

	-- On exit: stop jobs, drop status files and timers. Nothing to persist —
	-- every edit was written to its workspace override when it happened.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for _, timer in ipairs({ M._msg_timer, M._continuation_timer }) do
				if timer then
					timer:stop()
					timer:close()
				end
			end
			M._msg_timer = nil
			M._continuation_timer = nil

			local ok, session_mod = pcall(require, "nvim-agent.session")
			if ok then
				for _, sess in ipairs(session_mod.list()) do
					pcall(session_mod.remove_status, sess)
					require("nvim-agent.terminal").cleanup(sess.id)
				end
			end
		end,
		desc = "nvim-agent: clean up terminals on exit",
	})

	-- Saving any file in a session's active/ dir records it as a workspace
	-- override for that member. Covers :NvimAgent edit prompt|notes|dirs|role.
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = config.get().base_dir .. "/sessions/*/*/active/*",
		callback = function(ev)
			local active_dir = vim.fn.fnamemodify(ev.file, ":h")
			local sess = require("nvim-agent.session").get_by_active_dir(active_dir)
			if sess then
				require("nvim-agent.launcher").sync_session_file(sess, vim.fn.fnamemodify(ev.file, ":t"))
			end
		end,
		desc = "nvim-agent: save edited context file as a workspace override",
	})

	-- Continuation timer. Ticks every TICK_MS and evaluates each session on
	-- ITS OWN period (config.json: inbox_wakeup_interval, default 30 s). A
	-- session that has produced no terminal output for a whole period and
	-- has a pending trigger or new mail is nudged to resume.
	M._wake_state = {}
	M._continuation_timer = uv.new_timer()
	M._continuation_timer:start(
		M.TICK_MS,
		M.TICK_MS,
		vim.schedule_wrap(function()
			local ok, session_mod = pcall(require, "nvim-agent.session")
			if not ok then
				return
			end
			local now = uv.now()
			for _, sess in ipairs(session_mod.list()) do
				M.evaluate_wakeup(sess, now)
			end
		end)
	)

	-- Poll every 30 s for new messages addressed to the current session and
	-- surface a notification. Content is injected by the adapter's hook.
	M._msg_timer = uv.new_timer()
	M._msg_timer:start(
		30000,
		30000,
		vim.schedule_wrap(function()
			local ok, session_mod = pcall(require, "nvim-agent.session")
			if not ok then
				return
			end
			local sess = session_mod.get_current()
			if not sess or not sess.name then
				return
			end

			local msg_file = require("nvim-agent.workspace").instance_runtime_dir(sess.cwd or vim.fn.getcwd())
				.. "/messages/"
				.. sess.name
				.. ".md"
			local f = io.open(msg_file, "r")
			if not f then
				return
			end
			local content = f:read("*a")
			f:close()

			if content and content ~= "" then
				vim.notify(
					string.format("nvim-agent [%s]: new messages from peer agents", sess.name),
					vim.log.levels.INFO
				)
			end
		end)
	)
end

return M
