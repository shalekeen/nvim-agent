local M = {}

function M.send_selection()
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	if s[2] == 0 or e[2] == 0 then
		vim.notify("nvim-agent: no selection", vim.log.levels.WARN)
		return
	end
	local lines = vim.fn.getline(s[2], e[2])
	if type(lines) == "string" then
		lines = { lines }
	end
	if #lines == 0 then
		vim.notify("nvim-agent: empty selection", vim.log.levels.WARN)
		return
	end
	if #lines == 1 then
		lines[1] = string.sub(lines[1], s[3], e[3])
	else
		lines[1] = string.sub(lines[1], s[3])
		lines[#lines] = string.sub(lines[#lines], 1, e[3])
	end
	local text = table.concat(lines, "\n")
	local terminal = require("nvim-agent.terminal")
	terminal.open()
	vim.schedule(function()
		vim.api.nvim_paste(text, true, -1)
	end)
end

--- Open four file paths in a read-only 2×2 grid in a fresh tab.
local function open_2x2_grid(files)
	vim.cmd("tabnew")
	vim.cmd("edit " .. vim.fn.fnameescape(files[1]))
	vim.cmd("setlocal readonly")
	vim.cmd("vsplit " .. vim.fn.fnameescape(files[2]))
	vim.cmd("setlocal readonly")
	vim.cmd("wincmd h")
	vim.cmd("split " .. vim.fn.fnameescape(files[3]))
	vim.cmd("setlocal readonly")
	vim.cmd("wincmd l")
	vim.cmd("split " .. vim.fn.fnameescape(files[4]))
	vim.cmd("setlocal readonly")
	vim.cmd("wincmd =")
	vim.cmd("wincmd h")
	vim.cmd("wincmd k")
end

--- Context grid for a session: prompt, notes, pinned dirs, shared ephemeral.
local function context_grid_paths(sess)
	if not sess or not sess.active_dir then
		return nil
	end
	local process_dir = sess.process_dir or sess.active_dir
	return {
		sess.active_dir .. "/system_prompt.md",
		sess.active_dir .. "/user_notes.md",
		sess.active_dir .. "/persistent_dirs.json",
		process_dir .. "/ephemeral.json",
	}
end

function M.view_all_context()
	local ok, session_mod = pcall(require, "nvim-agent.session")
	local sess = ok and session_mod.get_current() or nil
	local files = context_grid_paths(sess)
	if not files then
		vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
		return
	end
	open_2x2_grid(files)
	vim.notify("Viewing all context files (read-only)", vim.log.levels.INFO)
end

function M.register()
	local ok, wk = pcall(require, "which-key")
	if not ok then
		error("nvim-agent: which-key.nvim is required but not found", 2)
	end
	local agent = require("nvim-agent")
	local ui = require("nvim-agent.ui")

	--- Run `fn(active_dir)` for a picked session, then sync it to its agent.
	local function with_session(prompt, fn)
		agent.pick_session(prompt, function(sess)
			if not sess or not sess.active_dir then
				return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
			end
			fn(sess.active_dir)
		end)
	end

	wk.add({
		{ "<leader>a", group = "Nvim-Agent", mode = "v" },
		{ "<leader>a", group = "Nvim-Agent" },

		{ "<leader>aT", agent.toggle, desc = "Toggle agent terminal" },
		{ "<leader>aQ", agent.graceful_quit, desc = "Graceful quit (sync + confirm)" },
		{ "<leader>ar", agent.refresh_context, desc = "Refresh context" },
		{ "<leader>av", M.view_all_context, desc = "View all context (prompt, notes, dirs, ephemeral)" },
		{
			"<leader>ae",
			function()
				local sess = require("nvim-agent.session").get_current()
				if not sess then
					return vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
				end
				vim.cmd("vsplit " .. vim.fn.fnameescape((sess.process_dir or sess.active_dir) .. "/ephemeral.json"))
			end,
			desc = "View ephemeral context",
		},
		{ "<leader>aR", function() with_session("Edit role for session", agent.edit_role) end, desc = "Edit live session role" },

		-- ── Workspaces ────────────────────────────────────────────────────
		{ "<leader>aw", group = "Workspace" },
		{ "<leader>awn", agent.workspace_new, desc = "New workspace" },
		{ "<leader>awl", function() agent.workspace_load() end, desc = "Load workspace (picker)" },
		{ "<leader>awL", agent.workspace_list, desc = "List workspaces" },
		{ "<leader>awr", function() agent.workspace_remove() end, desc = "Remove workspace" },
		{ "<leader>awR", function() agent.workspace_rename() end, desc = "Rename workspace" },
		{ "<leader>aws", function() agent.workspace_save_as() end, desc = "Save live workspace as (promote ephemeral)" },

		-- ── Agents: membership + global library ────────────────────────────
		{ "<leader>aa", group = "Agents" },
		{ "<leader>aaa", function() agent.agent_add() end, desc = "Add agent to workspace" },
		{ "<leader>aar", function() agent.agent_remove() end, desc = "Remove agent from workspace" },
		{ "<leader>aaR", function() agent.agent_restart() end, desc = "Relaunch exited agent" },
		{ "<leader>aad", agent.agent_define, desc = "Define new agent (global)" },
		{ "<leader>aac", function() agent.agent_copy() end, desc = "Copy agent (global)" },
		{ "<leader>aae", function() agent.agent_edit() end, desc = "Edit agent definition (global)" },
		{ "<leader>aax", function() agent.agent_delete() end, desc = "Delete agent (global)" },
		{ "<leader>aal", agent.agent_list, desc = "List agents" },
		{ "<leader>aas", agent.agent_save, desc = "Save session context → agent" },

		-- ── Sessions ──────────────────────────────────────────────────────
		{ "<leader>aS", group = "Sessions" },
		{ "<leader>aSl", agent.session_list, desc = "List sessions" },
		{ "<leader>aSs", function() agent.session_switch() end, desc = "Switch session" },

		-- ── Tmux ──────────────────────────────────────────────────────────
		{ "<leader>at", group = "Tmux Capture" },
		{ "<leader>ata", function() agent.tmux_add_capture() end, desc = "Add tmux pane capture" },
		{ "<leader>atc", function() agent.tmux_clear_captures() end, desc = "Clear all tmux captures" },
		{ "<leader>atv", function() agent.tmux_view_captures() end, desc = "View tmux captures" },

		-- ── Persistent dirs (session mirror → agent) ──────────────────────
		{ "<leader>ad", group = "Persistent Dirs" },
		{
			"<leader>ada",
			function()
				with_session("Add directory to session", function(active_dir)
					ui.input({ prompt = "", title = "Add Directory (Tag)" }, function(tag)
						if not tag or tag == "" then
							return
						end
						ui.input({ prompt = "", title = "Add Directory (Path)" }, function(path)
							if not path or path == "" then
								return
							end
							ui.input({ prompt = "", title = "Add Directory (Description)" }, function(description)
								if not description or description == "" then
									return
								end
								agent.add_persistent_dir(tag, vim.fn.expand(path), description, active_dir)
							end)
						end)
					end)
				end)
			end,
			desc = "Add directory",
		},
		{ "<leader>ade", function() with_session("Edit persistent dirs for session", agent.edit_persistent_dirs) end, desc = "Edit persistent dirs" },
		{ "<leader>adv", function() with_session("View persistent dirs for session", agent.view_persistent_dirs) end, desc = "View persistent dirs" },
		{
			"<leader>add",
			function()
				with_session("Delete directory from session", function(active_dir)
					local dirs_path = active_dir .. "/" .. require("nvim-agent.config").get().context_files.persistent_dirs
					local dirs = require("nvim-agent.context.persistent_dirs").load(dirs_path)
					if #dirs == 0 then
						return vim.notify("nvim-agent: no persistent dirs", vim.log.levels.INFO)
					end
					local options = {}
					for _, entry in ipairs(dirs) do
						table.insert(options, entry.tag .. " - " .. entry.path)
					end
					ui.select(options, { prompt = "Delete directory", width = 70 }, function(choice)
						if choice then
							agent.remove_persistent_dir(choice:match("^([^%s]+)"), active_dir)
						end
					end)
				end)
			end,
			desc = "Delete directory",
		},

		-- ── Notes (session mirror → agent) ────────────────────────────────
		{ "<leader>an", group = "Notes" },
		{
			"<leader>ana",
			function()
				with_session("Add note to session", function(active_dir)
					ui.input({ prompt = "", title = "Add Note (Tag)" }, function(tag)
						if not tag or tag == "" then
							return
						end
						ui.input({ prompt = "", title = "Add Note (Content)" }, function(content)
							if not content or content == "" then
								return
							end
							local notes_file = active_dir .. "/user_notes.md"
							local notes = vim.fn.filereadable(notes_file) == 1 and vim.fn.readfile(notes_file) or {}
							table.insert(notes, "")
							table.insert(notes, "## " .. tag)
							table.insert(notes, content)
							vim.fn.writefile(notes, notes_file)
							agent.sync_session(active_dir)
							vim.notify("Added note: " .. tag, vim.log.levels.INFO)
						end)
					end)
				end)
			end,
			desc = "Add note",
		},
		{ "<leader>ane", function() with_session("Edit notes for session", agent.edit_user_notes) end, desc = "Edit notes" },
		{ "<leader>anv", function() with_session("View notes for session", agent.view_user_notes) end, desc = "View notes" },
		{
			"<leader>and",
			function()
				with_session("Delete note from session", function(active_dir)
					local notes_file = active_dir .. "/user_notes.md"
					if vim.fn.filereadable(notes_file) == 0 then
						return vim.notify("No user notes found", vim.log.levels.INFO)
					end
					local lines = vim.fn.readfile(notes_file)
					local tags, tag_lines = {}, {}
					for i, line in ipairs(lines) do
						local tag = line:match("^## (.+)")
						if tag then
							table.insert(tags, tag)
							tag_lines[tag] = i
						end
					end
					if #tags == 0 then
						return vim.notify("No tagged notes found", vim.log.levels.INFO)
					end
					ui.select(tags, { prompt = "Delete note with tag", width = 70 }, function(choice)
						if not choice then
							return
						end
						local start_line = tag_lines[choice]
						local end_line = #lines
						for i = start_line + 1, #lines do
							if lines[i]:match("^## ") then
								end_line = i - 1
								break
							end
						end
						local new_lines = {}
						for i = 1, start_line - 1 do
							table.insert(new_lines, lines[i])
						end
						for i = end_line + 1, #lines do
							table.insert(new_lines, lines[i])
						end
						while #new_lines > 0 and new_lines[#new_lines]:match("^%s*$") do
							table.remove(new_lines)
						end
						vim.fn.writefile(new_lines, notes_file)
						agent.sync_session(active_dir)
						vim.notify("Deleted note: " .. choice, vim.log.levels.INFO)
					end)
				end)
			end,
			desc = "Delete note by tag",
		},

		-- ── System prompt (session mirror → agent) ────────────────────────
		{ "<leader>as", group = "System Prompt" },
		{
			"<leader>asa",
			function()
				with_session("Add to system prompt for session", function(active_dir)
					ui.input({ prompt = "", title = "Add to System Prompt (Content)" }, function(content)
						if not content or content == "" then
							return
						end
						local prompt_file = active_dir .. "/system_prompt.md"
						local prompt = vim.fn.filereadable(prompt_file) == 1 and vim.fn.readfile(prompt_file) or {}
						table.insert(prompt, "")
						table.insert(prompt, content)
						vim.fn.writefile(prompt, prompt_file)
						agent.sync_session(active_dir)
						vim.notify("System prompt added", vim.log.levels.INFO)
					end)
				end)
			end,
			desc = "Add to system prompt",
		},
		{ "<leader>ase", function() with_session("Edit system prompt for session", agent.edit_system_prompt) end, desc = "Edit system prompt" },
		{ "<leader>asv", function() with_session("View system prompt for session", agent.view_system_prompt) end, desc = "View system prompt" },
		{
			"<leader>asd",
			function()
				with_session("Reset system prompt for session", function(active_dir)
					ui.select({ "Yes", "No" }, { prompt = "Reset system prompt to the default?", width = 50 }, function(choice)
						if choice == "Yes" then
							local default = require("nvim-agent.config").get().default_system_prompt or ""
							vim.fn.writefile(vim.split(default, "\n", { plain = true }), active_dir .. "/system_prompt.md")
							agent.sync_session(active_dir)
							vim.notify("System prompt reset to default", vim.log.levels.INFO)
						end
					end)
				end)
			end,
			desc = "Reset system prompt to default",
		},

		-- ── History ───────────────────────────────────────────────────────
		{ "<leader>ah", group = "History" },
		{ "<leader>aha", function() agent.history_view_agent() end, desc = "View history for an agent (picker)" },
		{ "<leader>ahw", agent.history_view_workspace, desc = "View history for the live workspace" },
		{ "<leader>ahp", agent.history_view_project, desc = "View project history (all instances)" },
	})

	-- Visual mode keymaps (registered via vim.keymap.set so :<C-u> sets '< '> marks)
	vim.keymap.set(
		"v",
		"<leader>as",
		":<C-u>lua require('nvim-agent.keymaps').send_selection()<CR>",
		{ desc = "Send selection to agent", silent = true }
	)
	vim.keymap.set("v", "<leader>aT", agent.toggle, { desc = "Toggle agent terminal" })
end

return M
