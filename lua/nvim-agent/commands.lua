local M = {}

local function parse_args(arg_string)
	local args = {}
	for word in arg_string:gmatch("%S+") do
		table.insert(args, word)
	end
	return args
end

local function input_prompt(title, callback)
	local ui = require("nvim-agent.ui")
	ui.input({ prompt = "", title = title }, function(value)
		if value and value ~= "" then
			callback(value)
		end
	end)
end

local function select_flavor(prompt, callback)
	local ui = require("nvim-agent.ui")
	local flavors = require("nvim-agent.flavor").list()
	if #flavors == 0 then
		vim.notify("nvim-agent: no flavors found", vim.log.levels.INFO)
		return
	end
	ui.select(flavors, { prompt = prompt, width = 70 }, function(choice)
		if choice then
			callback(choice)
		end
	end)
end

local function select_checkpoint(prompt, callback)
	local ui = require("nvim-agent.ui")
	local sess = require("nvim-agent.session").get_current()
	local current = sess and require("nvim-agent.flavor").current(sess.active_dir)
	if not current then
		vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
		return
	end
	local checkpoints = require("nvim-agent.flavor.checkpoint").list(current)
	if #checkpoints == 0 then
		vim.notify("nvim-agent: no checkpoints", vim.log.levels.INFO)
		return
	end
	ui.select(checkpoints, { prompt = prompt, width = 70 }, function(choice)
		if choice then
			callback(choice)
		end
	end)
end

local SUBCOMMANDS = {
	"open",
	"close",
	"toggle",
	"refresh",
	"flavor",
	"checkpoint",
	"edit",
	"view",
	"dir",
	"setup",
	"session",
	"tmux",
	"workspace",
	"agent",
	"template",
	"role",
	"history",
}

local SESSION_SUBS = { "new", "list", "close" }
local TMUX_SUBS = { "add", "clear", "view" }
local WORKSPACE_SUBS = { "init", "new", "launch", "edit", "save", "list", "remove", "permissions" }
local AGENT_SUBS = { "new", "list", "remove", "save", "set-template" }
local TEMPLATE_SUBS = { "create", "list", "remove" }
local ROLE_SUBS = { "edit" }
local HISTORY_SUBS = { "agent", "workspace", "project" }

local FLAVOR_SUBS = { "create", "load", "save", "savebase", "list", "delete", "rename" }
local CHECKPOINT_SUBS = { "load", "list", "delete", "sync", "saveto" }
local EDIT_SUBS = { "prompt", "agent", "notes", "dirs" }
local VIEW_SUBS = { "prompt", "agent", "notes", "dirs" }
local DIR_SUBS = { "add", "remove" }

-- Map: top-level subcommand → list of valid actions for completing args[2].
local SECOND_LEVEL = {
	flavor = FLAVOR_SUBS,
	checkpoint = CHECKPOINT_SUBS,
	edit = EDIT_SUBS,
	view = VIEW_SUBS,
	dir = DIR_SUBS,
	session = SESSION_SUBS,
	tmux = TMUX_SUBS,
	workspace = WORKSPACE_SUBS,
	agent = AGENT_SUBS,
	template = TEMPLATE_SUBS,
	role = ROLE_SUBS,
	history = HISTORY_SUBS,
}

local function prefix_filter(list, prefix)
	prefix = "^" .. vim.pesc(prefix or "")
	local matches = {}
	for _, s in ipairs(list) do
		if s:find(prefix) then
			table.insert(matches, s)
		end
	end
	return matches
end

local function complete(_, cmd_line, _)
	local args = parse_args(cmd_line)
	-- Remove "NvimAgent" from front
	table.remove(args, 1)

	if #args == 0 then
		return SUBCOMMANDS
	end

	local sub = args[1]

	if #args == 1 then
		return prefix_filter(SUBCOMMANDS, sub)
	end

	-- Most subcommands just need second-level action completion.
	if #args == 2 and SECOND_LEVEL[sub] then
		return prefix_filter(SECOND_LEVEL[sub], args[2])
	end

	-- Third-level completions (subcommand + action + value).
	if sub == "flavor" then
		local action = args[2]
		if #args == 3 and (action == "load" or action == "delete" or action == "save" or action == "rename") then
			return prefix_filter(require("nvim-agent.flavor").list(), args[3])
		end
		if #args == 4 and action == "rename" then
			return {}
		end
	elseif sub == "checkpoint" then
		local action = args[2]
		if #args == 3 and (action == "load" or action == "delete") then
			local sess = require("nvim-agent.session").get_current()
			local current = sess and require("nvim-agent.flavor").current(sess.active_dir)
			if current then
				return prefix_filter(require("nvim-agent.flavor.checkpoint").list(current), args[3])
			end
		end
	elseif sub == "workspace" then
		if #args == 3 and args[2] == "launch" then
			local manifests = require("nvim-agent.workspace").workspace_list(vim.fn.getcwd())
			local names = {}
			for _, ws in ipairs(manifests) do
				table.insert(names, ws.name)
			end
			return prefix_filter(names, args[3])
		end
	elseif sub == "session" then
		if #args == 3 and args[2] == "close" then
			local sessions = require("nvim-agent.session").list()
			local names = {}
			for _, sess in ipairs(sessions) do
				table.insert(names, sess.name)
			end
			return prefix_filter(names, args[3])
		end
	end

	return {}
end

local function dispatch(opts)
	local agent = require("nvim-agent")
	local args = parse_args(opts.args)

	if #args == 0 then
		agent.toggle()
		return
	end

	local sub = args[1]

	if sub == "open" then
		agent.open()
	elseif sub == "close" then
		agent.close()
	elseif sub == "toggle" then
		agent.toggle()
	elseif sub == "refresh" then
		agent.refresh_context()
	elseif sub == "flavor" then
		local action = args[2]
		if not action then
			agent.flavor_list()
			return
		end
		if action == "create" then
			if args[3] then
				agent.flavor_create(args[3])
			else
				input_prompt("Create Flavor (Name)", agent.flavor_create)
			end
		elseif action == "load" then
			if args[3] then
				agent.flavor_load(args[3])
			else
				select_flavor("Load flavor:", agent.flavor_load)
			end
		elseif action == "save" then
			agent.flavor_save(args[3])
		elseif action == "savebase" then
			agent.save_to_base()
		elseif action == "list" then
			agent.flavor_list()
		elseif action == "delete" then
			if args[3] then
				agent.flavor_delete(args[3])
			else
				select_flavor("Delete flavor:", agent.flavor_delete)
			end
		elseif action == "rename" then
			if args[3] and args[4] then
				agent.flavor_rename(args[3], args[4])
			elseif args[3] then
				input_prompt("Rename Flavor (New Name for '" .. args[3] .. "')", function(new)
					agent.flavor_rename(args[3], new)
				end)
			else
				select_flavor("Rename flavor", function(old)
					input_prompt("Rename Flavor (New Name for '" .. old .. "')", function(new)
						agent.flavor_rename(old, new)
					end)
				end)
			end
		else
			vim.notify("nvim-agent: unknown flavor action '" .. action .. "'", vim.log.levels.ERROR)
		end
	elseif sub == "checkpoint" then
		local action = args[2]
		if not action then
			agent.checkpoint_list()
			return
		end
		if action == "load" then
			if args[3] then
				agent.checkpoint_load(args[3])
			else
				select_checkpoint("Load checkpoint:", agent.checkpoint_load)
			end
		elseif action == "list" then
			agent.checkpoint_list()
		elseif action == "delete" then
			if args[3] then
				agent.checkpoint_delete(args[3])
			else
				select_checkpoint("Delete checkpoint:", agent.checkpoint_delete)
			end
		elseif action == "sync" then
			agent.checkpoint_sync()
		elseif action == "saveto" then
			if args[3] then
				agent.checkpoint_save_to(args[3])
			else
				-- Show list of checkpoints + "Create new" option
				local ui = require("nvim-agent.ui")
				local sess = require("nvim-agent.session").get_current()
				local current = sess and require("nvim-agent.flavor").current(sess.active_dir)
				if not current then
					vim.notify("nvim-agent: no active flavor", vim.log.levels.ERROR)
					return
				end
				local cps = require("nvim-agent.flavor.checkpoint").list(current)
				local options = {}
				for _, cp in ipairs(cps) do
					table.insert(options, cp)
				end
				table.insert(options, "Create new checkpoint")

				ui.select(options, { prompt = "Save to checkpoint", width = 70 }, function(choice)
					if choice == "Create new checkpoint" then
						input_prompt("Create New Checkpoint (Name)", agent.checkpoint_save_to)
					elseif choice then
						agent.checkpoint_save_to(choice)
					end
				end)
			end
		else
			vim.notify("nvim-agent: unknown checkpoint action '" .. action .. "'", vim.log.levels.ERROR)
		end
	elseif sub == "edit" then
		local target = args[2]
		if target == "prompt" then
			agent.edit_system_prompt()
		elseif target == "agent" then
			agent.edit_agent_prompt()
		elseif target == "notes" then
			agent.edit_user_notes()
		elseif target == "dirs" then
			agent.edit_persistent_dirs()
		else
			vim.notify("nvim-agent: edit what? (prompt|agent|notes|dirs)", vim.log.levels.ERROR)
		end
	elseif sub == "view" then
		local target = args[2]
		if target == "prompt" then
			agent.view_system_prompt()
		elseif target == "agent" then
			agent.view_agent_prompt()
		elseif target == "notes" then
			agent.view_user_notes()
		elseif target == "dirs" then
			agent.view_persistent_dirs()
		else
			vim.notify("nvim-agent: view what? (prompt|agent|notes|dirs)", vim.log.levels.ERROR)
		end
	elseif sub == "setup" then
		agent.adapter_setup()
	elseif sub == "session" then
		local action = args[2]
		if not action or action == "new" then
			agent.new_session()
		elseif action == "list" then
			agent.session_list()
		elseif action == "close" then
			agent.session_close(args[3])
		else
			vim.notify("nvim-agent: session what? (new|list|close [name])", vim.log.levels.ERROR)
		end
	elseif sub == "dir" then
		local action = args[2]
		if action == "add" then
			if args[3] and args[4] then
				-- Remaining args after tag and path form the description
				local desc = table.concat(args, " ", 5)
				agent.add_persistent_dir(args[3], args[4], desc)
			else
				vim.notify("nvim-agent: usage: NvimAgent dir add <tag> <path> <description>", vim.log.levels.ERROR)
			end
		elseif action == "remove" then
			if args[3] then
				agent.remove_persistent_dir(args[3])
			else
				vim.notify("nvim-agent: usage: NvimAgent dir remove <tag>", vim.log.levels.ERROR)
			end
		else
			vim.notify("nvim-agent: dir what? (add|remove)", vim.log.levels.ERROR)
		end
	elseif sub == "tmux" then
		local action = args[2]
		if not action or action == "add" then
			local lines = args[3] and tonumber(args[3]) or nil
			agent.tmux_add_capture(lines)
		elseif action == "clear" then
			agent.tmux_clear_captures()
		elseif action == "view" then
			agent.tmux_view_captures()
		else
			vim.notify("nvim-agent: tmux what? (add [lines]|clear|view)", vim.log.levels.ERROR)
		end
	elseif sub == "workspace" then
		local action = args[2]
		if not action or action == "list" then
			agent.workspace_list()
		elseif action == "init" then
			agent.workspace_init()
		elseif action == "new" then
			agent.workspace_new()
		elseif action == "launch" then
			agent.workspace_launch_picker(args[3])
		elseif action == "edit" then
			agent.workspace_edit()
		elseif action == "save" then
			agent.workspace_save()
		elseif action == "remove" then
			agent.workspace_remove()
		elseif action == "permissions" then
			local adapter = require("nvim-agent.adapter").get_active()
			if adapter and adapter.setup_project_permissions then
				adapter:setup_project_permissions(vim.fn.getcwd())
			else
				vim.notify("nvim-agent: no adapter configured", vim.log.levels.ERROR)
			end
		else
			vim.notify("nvim-agent: workspace what? (init|new|launch [name]|edit|save|list|remove|permissions)", vim.log.levels.ERROR)
		end
	elseif sub == "agent" then
		local action = args[2]
		if not action or action == "list" then
			agent.agent_list_ui()
		elseif action == "new" then
			agent.agent_new_interactive()
		elseif action == "remove" then
			agent.agent_remove()
		elseif action == "save" then
			agent.agent_save_current()
		elseif action == "set-template" then
			agent.agent_set_template_ui()
		else
			vim.notify("nvim-agent: agent what? (new|list|remove|save|set-template)", vim.log.levels.ERROR)
		end
	elseif sub == "template" then
		local action = args[2]
		if not action or action == "list" then
			agent.template_list_ui()
		elseif action == "create" then
			agent.template_create_ui()
		elseif action == "remove" then
			agent.template_remove_ui()
		else
			vim.notify("nvim-agent: template what? (create|list|remove)", vim.log.levels.ERROR)
		end
	elseif sub == "role" then
		local action = args[2]
		if not action or action == "edit" then
			agent.edit_role()
		else
			vim.notify("nvim-agent: role what? (edit)", vim.log.levels.ERROR)
		end
	elseif sub == "history" then
		local action = args[2]
		if not action or action == "agent" then
			agent.history_view_agent(args[3])
		elseif action == "workspace" then
			agent.history_view_workspace()
		elseif action == "project" then
			agent.history_view_project()
		else
			vim.notify("nvim-agent: history what? (agent [name]|workspace|project)", vim.log.levels.ERROR)
		end
	else
		vim.notify("nvim-agent: unknown command '" .. sub .. "'", vim.log.levels.ERROR)
	end
end

function M.register()
	vim.api.nvim_create_user_command("NvimAgent", dispatch, {
		nargs = "*",
		complete = complete,
		desc = "nvim-agent: coding agent CLI host",
	})
end

return M
