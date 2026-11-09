local M = {}

local uv = vim.uv or vim.loop

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
	M._session_ticks = nil
	M._handled_msg_mtime = nil

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

	-- Continuation timer: every 30 s, check each agent terminal.
	-- When a terminal has been idle (changedtick unchanged) and has a pending
	-- trigger or message file, send a wakeup to resume inference.
	M._session_ticks = {}
	M._handled_msg_mtime = {}
	M._continuation_timer = uv.new_timer()
	M._continuation_timer:start(
		30000,
		30000,
		vim.schedule_wrap(function()
			local ok, session_mod = pcall(require, "nvim-agent.session")
			if not ok then
				return
			end

			local terminal = require("nvim-agent.terminal")
			local ws = require("nvim-agent.workspace")

			for _, sess in ipairs(session_mod.list()) do
				-- Scoped to this Neovim instance's runtime tree for the project
				-- the session was launched in (not the current :cd): a trigger
				-- written for "main" in another instance must not wake ours.
				local instance_dir = ws.instance_runtime_dir(sess.cwd or vim.fn.getcwd())
				local trigger_dir = instance_dir .. "/triggers"
				local msg_dir = instance_dir .. "/messages"
				local bufnr = sess.bufnr
				if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not sess.jobid then
					M._session_ticks[sess.id] = nil
					M._handled_msg_mtime[sess.id] = nil
				else
					local tick = vim.api.nvim_buf_get_changedtick(bufnr)
					local prev_tick = M._session_ticks[sess.id]
					M._session_ticks[sess.id] = tick

					-- Agents can opt out of the periodic nudge (config.json:
					-- inbox_wakeups=false); direct trigger_agent wakes still work.
					if prev_tick and tick == prev_tick and session_mod.config(sess).inbox_wakeups then
						local trigger_file = trigger_dir .. "/" .. sess.name .. ".md"
						local msg_file = msg_dir .. "/" .. sess.name .. ".md"
						local has_trigger = vim.fn.getfsize(trigger_file) > 0

						local msg_stat = uv.fs_stat(msg_file)
						local msg_mtime = nil
						if msg_stat and (msg_stat.size or 0) > 0 and msg_stat.mtime then
							msg_mtime = (msg_stat.mtime.sec or 0) * 1e9 + (msg_stat.mtime.nsec or 0)
						end
						local has_new_messages = msg_mtime ~= nil and msg_mtime ~= M._handled_msg_mtime[sess.id]

						if has_trigger or has_new_messages then
							terminal.send(sess.id, "You have pending messages or tasks. Please continue your work.\r")
							if has_trigger then
								-- Lock the trigger file: an MCP-side trigger_agent may
								-- be appending right now. Short retry budget so the
								-- timer never stalls; on lock failure we still truncate
								-- (the agent still has the message in its mailbox).
								local ok_lock, filelock = pcall(require, "nvim-agent.mcp.filelock")
								local got = ok_lock
									and filelock.acquire(trigger_file, { agent = "nvim-autocmd", retries = 1, delay_ms = 50 })
								local f = io.open(trigger_file, "w")
								if f then
									f:close()
								end
								if got then
									filelock.release(trigger_file)
								end
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
