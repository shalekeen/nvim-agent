local M = {}

function M.register()
	-- Idempotent: if register() is invoked twice (e.g. plugin reload), the old
	-- timers must be stopped before we allocate new ones, or they'll keep
	-- firing against torn-down state.
	for _, timer_key in ipairs({ "_continuation_timer", "_msg_timer" }) do
		local t = M[timer_key]
		if t then
			pcall(t.stop, t)
			pcall(t.close, t)
			M[timer_key] = nil
		end
	end
	M._session_ticks = nil
	M._handled_msg_mtime = nil

	local group = vim.api.nvim_create_augroup("NvimAgent", { clear = true })
	local config = require("nvim-agent.config")

	-- Write all context files when entering an agent terminal buffer.
	-- Identifies the owning session from the buffer number, marks it current,
	-- and updates ephemeral context for ALL sessions so every agent stays fresh.
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
						-- Ephemeral is written once to process_dir — shared by all sessions
						-- in this Neovim process, so no need to update other sessions.
						require("nvim-agent.context").write_all(sess.active_dir, sess.process_dir)
					end)
				end

				-- Call adapter's on_enter hook
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

	-- Warn when quitting with actively-running agent jobs.
	vim.api.nvim_create_autocmd("QuitPre", {
		group = group,
		callback = function()
			local ok, session_mod = pcall(require, "nvim-agent.session")
			if not ok then return end
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

	-- On exit: auto-save workspace sessions' state → def dir, then stop jobs and timers.
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
				local cwd = vim.fn.getcwd()
				local ok_ws, workspace_mod = pcall(require, "nvim-agent.workspace")
				for _, sess in ipairs(session_mod.list()) do
					-- Persist active_dir → workspace def dir for any workspace session.
					if ok_ws and workspace_mod.has_workspace(cwd) then
						pcall(workspace_mod.agent_save_content, sess.name, sess.active_dir, cwd)
					end
					require("nvim-agent.terminal").cleanup(sess.id)
				end
			end
		end,
		desc = "nvim-agent: save state and cleanup all agent terminals on exit",
	})

	-- Visual indicator when any session's context files are manually edited and saved
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = config.get().base_dir .. "/sessions/*/*/active/*",
		callback = function()
			vim.notify("nvim-agent: context file updated", vim.log.levels.INFO)
		end,
		desc = "nvim-agent: notify on context file save",
	})

	-- Continuation timer: every 30 s, check each agent terminal.
	-- When a terminal has been idle (changedtick unchanged) and has a pending
	-- trigger or message file, send a wakeup to resume inference.
	-- This prevents agents from silently stopping mid-task.
	M._session_ticks = {}
	-- Track the mtime of each session's message file we last fired a wake-up
	-- for. Without this we'd re-trigger every 30 s as long as the file is
	-- non-empty, even after the agent has acknowledged the wake-up but before
	-- read_messages truncates it.
	M._handled_msg_mtime = {}
	M._continuation_timer = vim.loop.new_timer()
	M._continuation_timer:start(
		30000,
		30000,
		vim.schedule_wrap(function()
			local ok, session_mod = pcall(require, "nvim-agent.session")
			if not ok then return end

			local cwd = vim.fn.getcwd()
			local trigger_dir = cwd .. "/.nvim-agent/triggers"
			local msg_dir = cwd .. "/.nvim-agent/messages"
			local terminal = require("nvim-agent.terminal")

			for _, sess in ipairs(session_mod.list()) do
				local bufnr = sess.bufnr
				if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
					M._session_ticks[sess.id] = nil
					M._handled_msg_mtime[sess.id] = nil
				else
					local tick = vim.api.nvim_buf_get_changedtick(bufnr)
					local prev_tick = M._session_ticks[sess.id]
					M._session_ticks[sess.id] = tick

					-- Terminal is idle when output hasn't changed since last poll
					if prev_tick and tick == prev_tick then
						local trigger_file = trigger_dir .. "/" .. sess.name .. ".md"
						local msg_file = msg_dir .. "/" .. sess.name .. ".md"
						local has_trigger = vim.fn.getfsize(trigger_file) > 0

						-- Re-fire the message wake-up only when the mailbox has
						-- been written to since we last fired. Use nanosecond
						-- precision so two writes in the same second don't
						-- collide on second-only granularity.
						local msg_stat = vim.loop.fs_stat(msg_file)
						local msg_mtime = nil
						if msg_stat and (msg_stat.size or 0) > 0 and msg_stat.mtime then
							msg_mtime = (msg_stat.mtime.sec or 0) * 1e9 + (msg_stat.mtime.nsec or 0)
						end
						local has_new_messages = msg_mtime ~= nil
							and msg_mtime ~= M._handled_msg_mtime[sess.id]

						if has_trigger or has_new_messages then
							terminal.send(
								sess.id,
								"You have pending messages or tasks. Please continue your work.\r"
							)
							if has_trigger then
								-- Lock the trigger file: an MCP-side trigger_agent
								-- may be appending right now; without the lock our
								-- truncate could clobber its write.
								-- Use a short retry budget so the editor's timer
								-- callback doesn't stall on contention; if we fail
								-- to lock, we still truncate (worst case is one
								-- racing MCP trigger write being lost — the agent
								-- still has the message in its mailbox).
								local ok_lock, filelock = pcall(require, "nvim-agent.mcp.filelock")
								local got = ok_lock
									and filelock.acquire(trigger_file, { agent = "nvim-autocmd", retries = 1, delay_ms = 50 })
								local f = io.open(trigger_file, "w")
								if f then f:close() end
								if got then filelock.release(trigger_file) end
							end
							if has_new_messages then
								M._handled_msg_mtime[sess.id] = msg_mtime
							end
						end
					end
				end
			end
		end)
	)

	-- Poll every 30 s for new messages addressed to the current session.
	-- Messages live in <cwd>/.nvim-agent/messages/<name>.md — project-local so
	-- they persist across Neovim restarts and are visible to all instances for
	-- this project. This timer only surfaces a Neovim notification; the full
	-- content is injected into the agent's context by the UserPromptSubmit hook.
	M._msg_timer = vim.loop.new_timer()
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

			local cwd = vim.fn.getcwd()
			local msg_file = cwd .. "/.nvim-agent/messages/" .. sess.name .. ".md"
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
