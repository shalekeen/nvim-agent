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
	-- Trim to selected columns
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

--- Open four file paths in a read-only 2×2 grid (top-left, top-right,
--- bottom-left, bottom-right). The grid lives in a fresh tab; cursor lands on
--- the top-left window.
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

--- Common save-target picker: prompts the user to save the active flavor's
--- context to either base, an existing checkpoint, or a new checkpoint name.
--- Used by both the "save flavor" and "save checkpoint" keymaps.
local function save_with_target_picker(prompt_label, active_dir, agent, ui)
	local current = require("nvim-agent.flavor").current(active_dir)
	if not current then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	local cps = require("nvim-agent.flavor.checkpoint").list(current)
	local options = { "base" }
	for _, cp in ipairs(cps) do
		table.insert(options, cp)
	end
	table.insert(options, "Create new checkpoint")

	ui.select(options, { prompt = prompt_label, width = 70 }, function(choice)
		if choice == "base" then
			agent.save_to_base(active_dir)
		elseif choice == "Create new checkpoint" then
			ui.input({ prompt = "", title = "Create New Checkpoint (Name)" }, function(name)
				if name and name ~= "" then
					agent.checkpoint_save_to(name, active_dir)
				end
			end)
		elseif choice then
			agent.checkpoint_save_to(choice, active_dir)
		end
	end)
end

--- Build the four context-file paths for a given session (active_dir +
--- process_dir). Returns nil when there is no current session.
local function context_grid_paths(sess)
	if not sess or not sess.active_dir then
		return nil
	end
	local active_dir = sess.active_dir
	local process_dir = sess.process_dir or active_dir
	return {
		active_dir .. "/system_prompt.md",
		active_dir .. "/user_notes.md",
		active_dir .. "/persistent_dirs.json",
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

	wk.add({
		-- Visual mode group label
		{ "<leader>a", group = "Nvim-Agent", mode = "v" },

		-- Top-level agent group
		{ "<leader>a", group = "Nvim-Agent" },

		-- Toggle terminal
		{ "<leader>aT", agent.toggle, desc = "Toggle agent terminal" },
		{ "<leader>aQ", agent.graceful_quit, desc = "Graceful quit (save + confirm)" },
		{ "<leader>ar", agent.refresh_context, desc = "Refresh context" },

		-- Tmux capture
		{ "<leader>at", group = "Tmux Capture" },
		{
			"<leader>ata",
			function()
				agent.tmux_add_capture()
			end,
			desc = "Add tmux pane capture",
		},
		{
			"<leader>atc",
			function()
				agent.tmux_clear_captures()
			end,
			desc = "Clear all tmux captures",
		},
		{
			"<leader>atv",
			function()
				agent.tmux_view_captures()
			end,
			desc = "View tmux captures",
		},

		-- Multi-session
		{ "<leader>aN", agent.new_session, desc = "New agent session" },
		{
			"<leader>aL",
			function()
				agent.session_list_picker()
			end,
			desc = "List/switch agent sessions",
		},

		-- ── Workspace (Mode 2: multi-agent, project-local) ─────────────────
		{ "<leader>aw", group = "Workspace" },

		-- Workspace lifecycle
		{
			"<leader>awi",
			function() agent.workspace_init() end,
			desc = "Init workspace (choose definition directory)",
		},
		{
			"<leader>awn",
			function() agent.workspace_new() end,
			desc = "New workspace definition (interactive)",
		},
		{
			"<leader>aws",
			function() agent.workspace_save() end,
			desc = "Save live sessions → workspace definition",
		},
		{
			"<leader>awl",
			function() agent.workspace_list() end,
			desc = "List workspace definitions",
		},
		{
			"<leader>awr",
			function() agent.workspace_remove() end,
			desc = "Remove workspace definition",
		},

		-- Agent management (all under <leader>awa)
		{ "<leader>awa", group = "Agents" },
		{
			"<leader>awan",
			function() agent.agent_new_interactive() end,
			desc = "New agent in workspace",
		},
		{
			"<leader>awal",
			function() agent.agent_list_ui() end,
			desc = "List agents",
		},
		{
			"<leader>awar",
			function() agent.agent_remove() end,
			desc = "Remove agent",
		},
		{
			"<leader>awas",
			function() agent.agent_save_current() end,
			desc = "Save live session → agent definition",
		},

		-- Edit agent definition files directly (picks agent, opens file in split)
		{ "<leader>awe", group = "Edit Agent Files" },
		{
			"<leader>awep",
			function() agent.edit_agent_file("system_prompt.md") end,
			desc = "Edit agent system prompt",
		},
		{
			"<leader>aweu",
			function() agent.edit_agent_file("user_notes.md") end,
			desc = "Edit agent user notes",
		},
		{
			"<leader>awed",
			function() agent.edit_agent_file("persistent_dirs.json") end,
			desc = "Edit agent persistent dirs",
		},
		{
			"<leader>awer",
			function() agent.edit_agent_file("role.md") end,
			desc = "Edit agent role",
		},

		-- Role for standalone sessions (Mode 1)
		-- Role (agent expertise/goals for multi-agent coordination)
		{
			"<leader>aR",
			function()
				agent.pick_session("Edit role for session", function(sess)
					agent.edit_role(sess and sess.active_dir)
				end)
			end,
			desc = "Edit live session role",
		},

		-- View all context files
		{
			"<leader>av",
			function()
				require("nvim-agent.keymaps").view_all_context()
			end,
			desc = "View all context (ephemeral, dirs, notes, system prompt)",
		},

		-- Persistent Dirs
		{ "<leader>ad", group = "Persistent Dirs" },
		{
			"<leader>ada",
			function()
				agent.pick_session("Add directory to session", function(sess_ada)
					local active_dir_ada = sess_ada and sess_ada.active_dir
					if not active_dir_ada then
						return
					end
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
								agent.add_persistent_dir(tag, vim.fn.expand(path), description, active_dir_ada)
								vim.notify("Added directory: " .. tag, vim.log.levels.INFO)
							end)
						end)
					end)
				end)
			end,
			desc = "Add directory",
		},
		{
			"<leader>ade",
			function()
				agent.pick_session("Edit persistent dirs for session", function(sess_ade)
					agent.edit_persistent_dirs(sess_ade and sess_ade.active_dir)
				end)
			end,
			desc = "Edit persistent dirs",
		},
		{
			"<leader>adv",
			function()
				agent.pick_session("View persistent dirs for session", function(sess_adv)
					agent.view_persistent_dirs(sess_adv and sess_adv.active_dir)
				end)
			end,
			desc = "View persistent dirs",
		},
		{
			"<leader>add",
			function()
				agent.pick_session("Delete directory from session", function(sess_dd)
					local active_dir_dd = sess_dd and sess_dd.active_dir
					if not active_dir_dd then
						return
					end
					local dirs_path = active_dir_dd
						.. "/"
						.. require("nvim-agent.config").get().context_files.persistent_dirs
					local persistent_dirs = require("nvim-agent.context.persistent_dirs")
					local dirs = persistent_dirs.load(dirs_path)
					if #dirs == 0 then
						vim.notify("nvim-agent: no persistent dirs", vim.log.levels.INFO)
						return
					end
					local options = {}
					for _, entry in ipairs(dirs) do
						table.insert(options, entry.tag .. " - " .. entry.path)
					end
					ui.select(options, { prompt = "Delete directory", width = 70 }, function(choice)
						if choice then
							local tag = choice:match("^([^%s]+)")
							agent.remove_persistent_dir(tag, active_dir_dd)
						end
					end)
				end)
			end,
			desc = "Delete directory",
		},

		-- Ephemeral
		{
			"<leader>ae",
			function()
				local ok_e, session_mod_e = pcall(require, "nvim-agent.session")
				local sess = ok_e and session_mod_e.get_current() or nil
				if not sess then
					vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
					return
				end
				local eph_dir = sess.process_dir or sess.active_dir
				vim.cmd("vsplit " .. vim.fn.fnameescape(eph_dir .. "/ephemeral.json"))
			end,
			desc = "View ephemeral context",
		},

		-- Notes
		{ "<leader>an", group = "Notes" },
		{
			"<leader>ana",
			function()
				agent.pick_session("Add note to session", function(sess_ana)
					local active_dir_ana = sess_ana and sess_ana.active_dir
					if not active_dir_ana then
						return
					end
					ui.input({ prompt = "", title = "Add Note (Tag)" }, function(tag)
						if not tag or tag == "" then
							return
						end
						ui.input({ prompt = "", title = "Add Note (Content)" }, function(content)
							if not content or content == "" then
								return
							end
							local notes_file = active_dir_ana .. "/user_notes.md"
							local notes = vim.fn.filereadable(notes_file) == 1 and vim.fn.readfile(notes_file) or {}
							table.insert(notes, "")
							table.insert(notes, "## " .. tag)
							table.insert(notes, content)
							vim.fn.writefile(notes, notes_file)
							vim.notify("Added note: " .. tag, vim.log.levels.INFO)
						end)
					end)
				end)
			end,
			desc = "Add note",
		},
		{
			"<leader>ane",
			function()
				agent.pick_session("Edit notes for session", function(sess_ane)
					agent.edit_user_notes(sess_ane and sess_ane.active_dir)
				end)
			end,
			desc = "Edit notes",
		},
		{
			"<leader>anv",
			function()
				agent.pick_session("View notes for session", function(sess_anv)
					agent.view_user_notes(sess_anv and sess_anv.active_dir)
				end)
			end,
			desc = "View notes",
		},
		{
			"<leader>and",
			function()
				agent.pick_session("Delete note from session", function(sess_nd)
					local active_dir_nd = sess_nd and sess_nd.active_dir
					if not active_dir_nd then
						return
					end
					local notes_file = active_dir_nd .. "/user_notes.md"
					if vim.fn.filereadable(notes_file) == 0 then
						vim.notify("No user notes found", vim.log.levels.INFO)
						return
					end

					local lines = vim.fn.readfile(notes_file)
					local tags = {}
					local tag_lines = {}

					for i, line in ipairs(lines) do
						if line:match("^## (.+)") then
							local tag = line:match("^## (.+)")
							table.insert(tags, tag)
							tag_lines[tag] = i
						end
					end

					if #tags == 0 then
						vim.notify("No tagged notes found", vim.log.levels.INFO)
						return
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
						vim.notify("Deleted note: " .. choice, vim.log.levels.INFO)
					end)
				end)
			end,
			desc = "Delete note by tag",
		},

		-- System Prompt
		{ "<leader>as", group = "System Prompt" },
		{
			"<leader>asa",
			function()
				agent.pick_session("Add to system prompt for session", function(sess_sa)
					local active_dir_sa = sess_sa and sess_sa.active_dir
					if not active_dir_sa then
						return
					end
					ui.input({ prompt = "", title = "Add to System Prompt (Content)" }, function(content)
						if not content or content == "" then
							return
						end
						local prompt_file = active_dir_sa .. "/system_prompt.md"
						local prompt = vim.fn.filereadable(prompt_file) == 1 and vim.fn.readfile(prompt_file) or {}
						table.insert(prompt, "")
						table.insert(prompt, content)
						vim.fn.writefile(prompt, prompt_file)
						vim.notify("System prompt added", vim.log.levels.INFO)
					end)
				end)
			end,
			desc = "Add to system prompt",
		},
		{
			"<leader>ase",
			function()
				agent.pick_session("Edit system prompt for session", function(sess_se)
					agent.edit_system_prompt(sess_se and sess_se.active_dir)
				end)
			end,
			desc = "Edit system prompt",
		},
		{
			"<leader>asv",
			function()
				agent.pick_session("View system prompt for session", function(sess_sv)
					agent.view_system_prompt(sess_sv and sess_sv.active_dir)
				end)
			end,
			desc = "View system prompt",
		},
		{
			"<leader>asd",
			function()
				agent.pick_session("Clear system prompt for session", function(sess_sd)
					local active_dir_sd = sess_sd and sess_sd.active_dir
					if not active_dir_sd then
						return
					end
					local prompt_file = active_dir_sd .. "/system_prompt.md"
					if vim.fn.filereadable(prompt_file) == 1 then
						ui.select({ "Yes", "No" }, { prompt = "Delete system prompt?", width = 50 }, function(choice)
							if choice == "Yes" then
								vim.fn.writefile({
									"# System Prompt",
									"",
									"You are a coding assistant working inside Neovim.",
									"Follow the user's instructions carefully and write clean, idiomatic code.",
								}, prompt_file)
								vim.notify("System prompt cleared", vim.log.levels.INFO)
							end
						end)
					else
						vim.notify("No system prompt found", vim.log.levels.INFO)
					end
				end)
			end,
			desc = "Delete system prompt",
		},

		-- History group
		{ "<leader>ah", group = "History" },
		{
			"<leader>aha",
			function() agent.history_view_agent() end,
			desc = "View history for an agent (picker)",
		},
		{
			"<leader>ahw",
			function() agent.history_view_workspace() end,
			desc = "View history for all workspace agents",
		},
		{
			"<leader>ahp",
			function() agent.history_view_project() end,
			desc = "View project history (all agents)",
		},

		-- Flavor group
		{ "<leader>af", group = "Flavor" },
		{
			"<leader>afc",
			function()
				ui.input({ prompt = "", title = "Create Flavor (Name)" }, function(name)
					if name and name ~= "" then
						agent.flavor_create(name)
					end
				end)
			end,
			desc = "Create flavor",
		},
		{
			"<leader>afl",
			function()
				agent.pick_session("Load flavor for session", function(sess_fl)
					local active_dir_fl = sess_fl and sess_fl.active_dir
					if not active_dir_fl then
						return
					end
					local flavors = require("nvim-agent.flavor").list()
					if #flavors == 0 then
						vim.notify("nvim-agent: no flavors found", vim.log.levels.INFO)
						return
					end
					ui.select(flavors, { prompt = "Load flavor", width = 70 }, function(choice)
						if choice then
							agent.flavor_load(choice, active_dir_fl)
						end
					end)
				end)
			end,
			desc = "Load flavor",
		},
		{
			"<leader>afs",
			function()
				agent.pick_session("Save flavor for session", function(sess_fs)
					if sess_fs and sess_fs.active_dir then
						save_with_target_picker("Save to", sess_fs.active_dir, agent, ui)
					end
				end)
			end,
			desc = "Save Flavor",
		},
		{
			"<leader>afd",
			function()
				local flavors = require("nvim-agent.flavor").list()
				if #flavors == 0 then
					vim.notify("nvim-agent: no flavors found", vim.log.levels.INFO)
					return
				end
				ui.select(flavors, { prompt = "Delete flavor", width = 70 }, function(choice)
					if choice then
						agent.flavor_delete(choice)
					end
				end)
			end,
			desc = "Delete flavor",
		},
		{
			"<leader>afr",
			function()
				local flavors = require("nvim-agent.flavor").list()
				if #flavors == 0 then
					vim.notify("nvim-agent: no flavors found", vim.log.levels.INFO)
					return
				end
				ui.select(flavors, { prompt = "Rename flavor", width = 70 }, function(old)
					if old then
						ui.input({ prompt = "", title = "Rename Flavor (New Name for '" .. old .. "')" }, function(new)
							if new and new ~= "" then
								agent.flavor_rename(old, new)
							end
						end)
					end
				end)
			end,
			desc = "Rename flavor",
		},
		{
			"<leader>afv",
			function()
				-- Use session active_dir so we read the right flavor meta
				local ok_fv, session_mod_fv = pcall(require, "nvim-agent.session")
				local sess_fv = ok_fv and session_mod_fv.get_current() or nil
				local active_dir_fv = sess_fv and sess_fv.active_dir
				if not active_dir_fv then
					vim.notify("nvim-agent: no active session", vim.log.levels.WARN)
					return
				end
				local flav = require("nvim-agent.flavor")
				local current = flav.current(active_dir_fv)
				if not current then
					vim.notify("nvim-agent: no active flavor", vim.log.levels.INFO)
					return
				end
				local cp = flav.current_checkpoint(active_dir_fv)
				local cp_label = cp and ("@ " .. cp) or "@ base"

				open_2x2_grid(context_grid_paths(sess_fv))
				vim.notify(string.format("Flavor: %s %s (read-only)", current, cp_label), vim.log.levels.INFO)
			end,
			desc = "View current flavor context",
		},

		-- Checkpoint group
		{ "<leader>afC", group = "Checkpoint" },
		{
			"<leader>afCl",
			function()
				agent.pick_session("Load checkpoint for session", function(sess_cl)
					local active_dir_cl = sess_cl and sess_cl.active_dir
					if not active_dir_cl then
						return
					end
					local current = require("nvim-agent.flavor").current(active_dir_cl)
					if not current then
						vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
						return
					end
					local cps = require("nvim-agent.flavor.checkpoint").list(current)
					if #cps == 0 then
						vim.notify("nvim-agent: no checkpoints", vim.log.levels.INFO)
						return
					end
					ui.select(cps, { prompt = "Load checkpoint", width = 70 }, function(choice)
						if choice then
							agent.checkpoint_load(choice, active_dir_cl)
						end
					end)
				end)
			end,
			desc = "Load checkpoint",
		},
		{
			"<leader>afCd",
			function()
				agent.pick_session("Delete checkpoint for session", function(sess_cd)
					local active_dir_cd = sess_cd and sess_cd.active_dir
					if not active_dir_cd then
						return
					end
					local current = require("nvim-agent.flavor").current(active_dir_cd)
					if not current then
						vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
						return
					end
					local cps = require("nvim-agent.flavor.checkpoint").list(current)
					if #cps == 0 then
						vim.notify("nvim-agent: no checkpoints", vim.log.levels.INFO)
						return
					end
					ui.select(cps, { prompt = "Delete checkpoint", width = 70 }, function(choice)
						if choice then
							agent.checkpoint_delete(choice)
						end
					end)
				end)
			end,
			desc = "Delete checkpoint",
		},
		{
			"<leader>afCv",
			function()
				agent.pick_session("View checkpoints for session", function(sess_cv)
					local active_dir_cv = sess_cv and sess_cv.active_dir
					if not active_dir_cv then
						return
					end
					local current = require("nvim-agent.flavor").current(active_dir_cv)
					if not current then
						vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
						return
					end
					local cps = require("nvim-agent.flavor.checkpoint").list(current)
					if #cps == 0 then
						vim.notify("No checkpoints for flavor: " .. current, vim.log.levels.INFO)
					else
						vim.notify(
							"Checkpoints for " .. current .. ":\n" .. table.concat(cps, "\n"),
							vim.log.levels.INFO
						)
					end
				end)
			end,
			desc = "View checkpoints",
		},
		{
			"<leader>afCy",
			agent.checkpoint_sync,
			desc = "Sync checkpoint with base",
		},
		{
			"<leader>afCs",
			function()
				agent.pick_session("Save checkpoint for session", function(sess_cs)
					if sess_cs and sess_cs.active_dir then
						save_with_target_picker("Save to", sess_cs.active_dir, agent, ui)
					end
				end)
			end,
			desc = "Save Checkpoint",
		},
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
