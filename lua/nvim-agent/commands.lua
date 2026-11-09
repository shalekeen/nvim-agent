local M = {}

local function parse_args(arg_string)
	local args = {}
	for word in arg_string:gmatch("%S+") do
		table.insert(args, word)
	end
	return args
end

local SUBCOMMANDS = {
	"open",
	"close",
	"toggle",
	"refresh",
	"arrange",
	"status",
	"send",
	"workspace",
	"agent",
	"session",
	"edit",
	"view",
	"dir",
	"role",
	"tmux",
	"history",
	"setup",
}

local OPEN_SUBS = { "all" }
local WORKSPACE_SUBS = { "new", "load", "list", "remove", "rename", "save-as" }
local AGENT_SUBS = { "add", "remove", "stop", "restart", "define", "copy", "edit", "delete", "list", "push", "overrides", "reset" }
local SESSION_SUBS = { "list", "switch" }
local EDIT_SUBS = { "prompt", "notes", "dirs", "role", "config" }
local VIEW_SUBS = { "prompt", "notes", "dirs", "role", "config" }
local DIR_SUBS = { "add", "remove" }
local ROLE_SUBS = { "edit", "view" }
local TMUX_SUBS = { "add", "clear", "view" }
local HISTORY_SUBS = { "agent", "workspace", "project", "open" }

local SECOND_LEVEL = {
	open = OPEN_SUBS,
	close = OPEN_SUBS,
	workspace = WORKSPACE_SUBS,
	agent = AGENT_SUBS,
	session = SESSION_SUBS,
	edit = EDIT_SUBS,
	view = VIEW_SUBS,
	dir = DIR_SUBS,
	role = ROLE_SUBS,
	tmux = TMUX_SUBS,
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

local function workspace_names()
	local names = {}
	for _, m in ipairs(require("nvim-agent.workspace").list(vim.fn.getcwd())) do
		table.insert(names, m.name)
	end
	return names
end

local function library_agent_names()
	local names = {}
	for _, a in ipairs(require("nvim-agent.agent").list()) do
		table.insert(names, a.name)
	end
	return names
end

local function member_names()
	local m = require("nvim-agent.workspace").get_current()
	local names = {}
	for _, e in ipairs(m and m.agents or {}) do
		table.insert(names, e.name)
	end
	return names
end

local function session_names()
	local names = {}
	for _, sess in ipairs(require("nvim-agent.session").list()) do
		table.insert(names, sess.name)
	end
	return names
end

local function complete(_, cmd_line, _)
	local args = parse_args(cmd_line)
	table.remove(args, 1) -- "NvimAgent"

	local trailing = cmd_line:sub(-1) == " "
	local n = #args + (trailing and 1 or 0)
	local cur = trailing and "" or (args[#args] or "")

	if n <= 1 then
		return prefix_filter(SUBCOMMANDS, cur)
	end

	local sub = args[1]
	if n == 2 then
		if sub == "send" then
			return prefix_filter(session_names(), cur)
		end
		return prefix_filter(SECOND_LEVEL[sub] or {}, cur)
	end

	local action = args[2]
	if n == 3 then
		if sub == "workspace" and (action == "load" or action == "remove" or action == "rename") then
			return prefix_filter(workspace_names(), cur)
		elseif sub == "agent" then
			if action == "add" or action == "copy" or action == "edit" or action == "delete" then
				return prefix_filter(library_agent_names(), cur)
			elseif action == "remove" or action == "restart" or action == "stop" or action == "push" or action == "reset" then
				return prefix_filter(member_names(), cur)
			end
		elseif sub == "session" and action == "switch" then
			return prefix_filter(session_names(), cur)
		elseif sub == "history" and action == "agent" then
			return prefix_filter(session_names(), cur)
		end
	end

	if n == 4 and sub == "agent" and action == "reset" then
		return prefix_filter(require("nvim-agent.agent").AGENT_FILES, cur)
	end

	return {}
end

local function usage(msg)
	vim.notify("nvim-agent: " .. msg, vim.log.levels.ERROR)
end

local function dispatch(opts)
	local agent = require("nvim-agent")
	local args = parse_args(opts.args)

	if #args == 0 then
		return agent.toggle()
	end

	local sub, action = args[1], args[2]

	if sub == "open" then
		if action == "all" then
			agent.arrange_all()
		else
			agent.open()
		end
	elseif sub == "close" then
		if action == "all" then
			agent.close_all()
		else
			agent.close()
		end
	elseif sub == "toggle" then
		agent.toggle()
	elseif sub == "refresh" then
		agent.refresh_context()
	elseif sub == "arrange" then
		agent.arrange_all()
	elseif sub == "status" then
		agent.team_status()
	elseif sub == "send" then
		if not action then
			agent.send_message()
		else
			agent.send_message(action, table.concat(args, " ", 3))
		end
	elseif sub == "setup" then
		agent.adapter_setup()
	elseif sub == "workspace" then
		if not action or action == "list" then
			agent.workspace_list()
		elseif action == "new" then
			agent.workspace_new()
		elseif action == "load" then
			agent.workspace_load(args[3])
		elseif action == "remove" then
			agent.workspace_remove(args[3])
		elseif action == "rename" then
			agent.workspace_rename(args[3], args[4])
		elseif action == "save-as" then
			agent.workspace_save_as(args[3])
		else
			usage("workspace what? (new|load [name]|list|remove [name]|rename [old] [new]|save-as [name])")
		end
	elseif sub == "agent" then
		if not action or action == "list" then
			agent.agent_list()
		elseif action == "add" then
			agent.agent_add(args[3], args[4])
		elseif action == "remove" then
			agent.agent_remove(args[3])
		elseif action == "stop" then
			agent.agent_stop(args[3])
		elseif action == "restart" then
			agent.agent_restart(args[3])
		elseif action == "define" then
			agent.agent_define()
		elseif action == "copy" then
			agent.agent_copy(args[3], args[4])
		elseif action == "edit" then
			agent.agent_edit(args[3])
		elseif action == "delete" then
			agent.agent_delete(args[3])
		elseif action == "push" or action == "save" then
			agent.agent_push(args[3])
		elseif action == "overrides" then
			agent.agent_overrides()
		elseif action == "reset" then
			agent.agent_reset(args[3], args[4])
		else
			usage(
				"agent what? (add [agent] [as-name]|remove [name]|stop [name]|restart [name]|define|copy [src] [dst]|edit [name]|delete [name]|list|push [name]|overrides|reset [name] [file])"
			)
		end
	elseif sub == "session" then
		if not action or action == "list" then
			agent.session_list()
		elseif action == "switch" then
			agent.session_switch(args[3])
		else
			usage("session what? (list|switch [name|n])")
		end
	elseif sub == "edit" then
		if action == "prompt" then
			agent.edit_system_prompt()
		elseif action == "notes" then
			agent.edit_user_notes()
		elseif action == "dirs" then
			agent.edit_persistent_dirs()
		elseif action == "role" then
			agent.edit_role()
		elseif action == "config" then
			agent.edit_agent_config()
		else
			usage("edit what? (prompt|notes|dirs|role|config)")
		end
	elseif sub == "view" then
		if action == "prompt" then
			agent.view_system_prompt()
		elseif action == "notes" then
			agent.view_user_notes()
		elseif action == "dirs" then
			agent.view_persistent_dirs()
		elseif action == "role" then
			agent.view_role()
		elseif action == "config" then
			agent.view_agent_config()
		else
			usage("view what? (prompt|notes|dirs|role|config)")
		end
	elseif sub == "dir" then
		if action == "add" then
			if args[3] and args[4] then
				agent.add_persistent_dir(args[3], args[4], table.concat(args, " ", 5))
			else
				usage("usage: NvimAgent dir add <tag> <path> <description>")
			end
		elseif action == "remove" then
			if args[3] then
				agent.remove_persistent_dir(args[3])
			else
				usage("usage: NvimAgent dir remove <tag>")
			end
		else
			usage("dir what? (add|remove)")
		end
	elseif sub == "role" then
		if not action or action == "edit" then
			agent.edit_role()
		elseif action == "view" then
			agent.view_role()
		else
			usage("role what? (edit|view)")
		end
	elseif sub == "tmux" then
		if not action or action == "add" then
			agent.tmux_add_capture(args[3] and tonumber(args[3]) or nil)
		elseif action == "clear" then
			agent.tmux_clear_captures()
		elseif action == "view" then
			agent.tmux_view_captures()
		else
			usage("tmux what? (add [lines]|clear|view)")
		end
	elseif sub == "history" then
		if not action or action == "agent" then
			agent.history_view_agent(args[3])
		elseif action == "workspace" then
			agent.history_view_workspace()
		elseif action == "project" then
			agent.history_view_project()
		elseif action == "open" then
			agent.history_open()
		else
			usage("history what? (agent [name]|workspace|project|open)")
		end
	else
		usage("unknown command '" .. sub .. "'")
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
