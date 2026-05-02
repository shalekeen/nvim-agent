-- MCP tool definitions and handlers for Neovim control

local nvim_rpc = require("nvim_rpc")
local json = vim.json
local filelock = require("filelock")

-- Context directories inherited from the Claude Code process environment.
-- Each Claude Code process launched by nvim-agent has these set:
--   NVIM_AGENT_ACTIVE_DIR  — session-specific dir (flavor files: system_prompt, notes, dirs, meta)
--   NVIM_AGENT_PROCESS_DIR — process-level dir (ephemeral.json, shared by all sessions)
--   NVIM_AGENT_CWD         — working directory of the project
local ACTIVE_DIR = os.getenv("NVIM_AGENT_ACTIVE_DIR") or ""
local CWD = os.getenv("NVIM_AGENT_CWD") or ""

-- Derive this agent's name from the active dir path.
-- ACTIVE_DIR structure: .../.nvim-agent/sessions/<pid>/<name>/active
local AGENT_NAME = ACTIVE_DIR:match("/([^/]+)/active/?$") or "unknown"

------------------------------------------------------------------------
-- Messaging and coordination helpers (pure file I/O — no Neovim RPC)
-- All runtime communication lives in <cwd>/.nvim-agent/:
--   messages/<name>.md  — per-agent mailbox (append-only, cleared on read)
--   status/<name>.json  — per-agent status + role (last written wins)
------------------------------------------------------------------------

local function project_comm_dir(subdir)
	return CWD .. "/.nvim-agent/" .. subdir
end

--- List names of all peer agents that have written a status file.
--- Peers are discovered from CWD/.nvim-agent/status/*.json (excludes self).
local function list_peer_names()
	local peers = {}
	if CWD == "" then
		return peers
	end
	local handle = io.popen('ls "' .. project_comm_dir("status") .. '"/*.json 2>/dev/null')
	if not handle then
		return peers
	end
	for path in handle:lines() do
		local name = path:match("/([^/]+)%.json$")
		if name and name ~= AGENT_NAME then
			table.insert(peers, name)
		end
	end
	handle:close()
	return peers
end

--- Atomically write `content` to `path` via a `<path>.tmp` rename. A reader
--- that opens `path` will always see either the previous valid content or
--- the new full content — never a half-written file.
local function atomic_write(path, content)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		return false, "could not open " .. tmp .. " for writing"
	end
	f:write(content)
	f:close()
	local ok, err = os.rename(tmp, path)
	if not ok then
		os.remove(tmp)
		return false, "rename failed: " .. tostring(err)
	end
	return true
end

--- Run a function while holding an exclusive lock on `path`. Releases the
--- lock unconditionally afterwards (idempotent), even if `fn` errors.
local function with_lock(path, fn)
	local got, lock_err = filelock.acquire(path, { agent = AGENT_NAME })
	if not got then
		return nil, lock_err
	end
	local ok, ret_or_err, second = pcall(fn)
	filelock.release(path)
	if not ok then
		return nil, tostring(ret_or_err)
	end
	return ret_or_err, second
end

--- Append a formatted message to a recipient's mailbox file. Holds an
--- exclusive lock so concurrent senders cannot interleave bytes.
local function deliver_message(recipient, from, content)
	if CWD == "" then
		return false, "NVIM_AGENT_CWD not set"
	end
	local msg_dir = project_comm_dir("messages")
	os.execute("mkdir -p " .. msg_dir)
	local path = msg_dir .. "/" .. recipient .. ".md"
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local block = string.format("\n---\n**From: %s** | %s\n\n%s\n", from, timestamp, content)
	local ok, err = with_lock(path, function()
		local f = io.open(path, "a")
		if not f then
			error("could not open mailbox for " .. recipient)
		end
		f:write(block)
		f:close()
		return true
	end)
	if not ok then
		return false, err
	end
	return true
end

--- Read the full contents of a file, or return nil if it doesn't exist.
local function read_file_contents(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Append a timestamped entry to a history file, creating it if needed.
--- Locked because two instances of the same agent (e.g. across a session
--- restart) could otherwise interleave writes to the same file.
local function append_history(path, agent, summary)
	os.execute("mkdir -p " .. path:match("(.+)/[^/]+$"))
	local timestamp = os.date("%Y-%m-%d %H:%M")
	local block = string.format("\n---\n**[%s] Agent: %s**\n\n%s\n", timestamp, agent, summary)
	local ok = with_lock(path, function()
		local f = io.open(path, "a")
		if not f then
			error("could not open " .. path)
		end
		f:write(block)
		f:close()
		return true
	end)
	return ok ~= nil
end

local M = {}

------------------------------------------------------------------------
-- Tool definitions (MCP schema)
------------------------------------------------------------------------

M.definitions = {

	-- ----------------------------------------------------------------
	-- Primary tools — use these for all file operations
	-- ----------------------------------------------------------------

	{
		name = "read_file",
		description = "Read a file from disk by path. Reads directly without opening the file in the editor. Supports reading a specific line range to avoid fetching entire large files.",
		inputSchema = {
			type = "object",
			properties = {
				filepath = {
					type = "string",
					description = "Absolute path to the file to read",
				},
				start_line = {
					type = "number",
					description = "First line to read (1-indexed, inclusive). Omit to start from line 1.",
				},
				end_line = {
					type = "number",
					description = "Last line to read (1-indexed, inclusive). Omit to read to end of file.",
				},
			},
			required = { "filepath" },
		},
	},

	{
		name = "edit_buffer",
		description = "Create or edit a file in Neovim. You MUST specify either a line range (start_line + end_line) for a targeted edit, or set replace_entire_file=true to intentionally replace the whole file. Omitting both is an error to prevent accidental data loss.",
		inputSchema = {
			type = "object",
			properties = {
				filepath = {
					type = "string",
					description = "Absolute path to the file to create or edit",
				},
				content = {
					type = "string",
					description = "New content as a plain string. For range edits, this replaces only the specified lines. For full-file replacement, this becomes the entire file content.",
				},
				start_line = {
					type = "number",
					description = "First line to replace (1-indexed). Must be provided together with end_line.",
				},
				end_line = {
					type = "number",
					description = "Last line to replace (1-indexed, inclusive). Must be provided together with start_line.",
				},
				replace_entire_file = {
					type = "boolean",
					description = "Set to true to intentionally replace the entire file content. Required when start_line/end_line are not provided. Prevents accidental full-file overwrites.",
				},
				save = {
					type = "boolean",
					description = "Save the file after editing (default: true). Should almost always be true.",
				},
				review = {
					type = "boolean",
					description = "Review mode (default false). When false (silent mode), the buffer is saved and closed immediately — the user does not see it. When true, the buffer is saved and left open in the editor so the user can review the changes.",
				},
				cursor_line = {
					type = "number",
					description = "Optional: line to position the cursor on after editing (1-indexed)",
				},
			},
			required = { "filepath", "content" },
		},
	},

	{
		name = "search_file",
		description = "Search for a Lua pattern (similar to regex) in a file. Returns matching lines with line numbers and optional context. Use the returned start_line/end_line ranges directly with read_file or edit_buffer for targeted operations.",
		inputSchema = {
			type = "object",
			properties = {
				filepath = {
					type = "string",
					description = "Absolute path to the file to search",
				},
				pattern = {
					type = "string",
					description = "Lua pattern to search for (e.g. 'function foo', 'class %w+', 'TODO'). Use plain string characters for literal matches.",
				},
				context_lines = {
					type = "number",
					description = "Number of lines of context to include above and below each match (default: 0)",
				},
			},
			required = { "filepath", "pattern" },
		},
	},

	{
		name = "execute_command",
		description = "Execute a Neovim ex command and return its output (e.g. 'w' to save, 'set number', 'grep foo **/*.lua'). Returns the captured command output.",
		inputSchema = {
			type = "object",
			properties = {
				command = {
					type = "string",
					description = "The ex command to run (without the leading ':')",
				},
			},
			required = { "command" },
		},
	},

	{
		name = "list_buffers",
		description = "List all open file buffers in Neovim. Returns buffer number, file path, modified status, and filetype. Special buffers (NvimTree, terminal, dashboard) are excluded.",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	-- ----------------------------------------------------------------
	-- Advanced / buffer-number-based tools
	-- ----------------------------------------------------------------

	{
		name = "get_buffer_content",
		description = "Advanced: Get the in-memory content of an open buffer by buffer number. Returns the current buffer state, which may include unsaved changes not yet written to disk. For reading files by path, use read_file instead.",
		inputSchema = {
			type = "object",
			properties = {
				bufnr = {
					type = "number",
					description = "Buffer number (obtain from list_buffers)",
				},
			},
			required = { "bufnr" },
		},
	},

	{
		name = "set_buffer_content",
		description = "Advanced: Replace the entire in-memory content of a buffer without saving to disk. Use edit_buffer for most edits. This is useful when you need to stage changes before a manual save.",
		inputSchema = {
			type = "object",
			properties = {
				bufnr = {
					type = "number",
					description = "Buffer number (obtain from list_buffers)",
				},
				lines = {
					type = "array",
					description = "Array of strings, each a line of the new content",
					items = { type = "string" },
				},
			},
			required = { "bufnr", "lines" },
		},
	},

	{
		name = "open_buffer",
		description = "Load a file into a Neovim buffer and return its buffer number. The buffer is added to the buffer list but does not switch the active window or move the cursor. Use read_file if you only need file contents without creating a buffer.",
		inputSchema = {
			type = "object",
			properties = {
				filepath = {
					type = "string",
					description = "Absolute or relative path to the file to open",
				},
			},
			required = { "filepath" },
		},
	},

	{
		name = "close_buffer",
		description = "Close a buffer by its number. By default fails if the buffer has unsaved changes; set force=true to discard them.",
		inputSchema = {
			type = "object",
			properties = {
				bufnr = {
					type = "number",
					description = "Buffer number to close",
				},
				force = {
					type = "boolean",
					description = "Discard unsaved changes and force close (default: false)",
				},
			},
			required = { "bufnr" },
		},
	},

	{
		name = "set_cursor",
		description = "Move the cursor to a specific position in the current window",
		inputSchema = {
			type = "object",
			properties = {
				row = {
					type = "number",
					description = "Row number (1-indexed)",
				},
				col = {
					type = "number",
					description = "Column number (0-indexed)",
				},
			},
			required = { "row", "col" },
		},
	},

	{
		name = "get_cursor",
		description = "Get the current cursor position in the active window",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	-- ----------------------------------------------------------------
	-- Agent-to-agent communication tools
	-- ----------------------------------------------------------------

	{
		name = "trigger_agent",
		description = "Send a message to a peer agent AND immediately wake their terminal so they start working. "
			.. "Unlike send_message (passive — waits for recipient's next prompt), trigger_agent "
			.. "delivers the message to the mailbox AND sends a wakeup keystroke to the recipient's "
			.. "terminal right now. Use this when another agent must act immediately — e.g. after "
			.. "you finish a deliverable they are blocked on.",
		inputSchema = {
			type = "object",
			properties = {
				to = {
					type = "string",
					description = "Target agent name (must be an active session, e.g. 'pm', 'researcher')",
				},
				message = {
					type = "string",
					description = "Instruction or context to deliver before waking the agent",
				},
			},
			required = { "to", "message" },
		},
	},

	{
		name = "send_message",
		description = "Send a message to a peer agent by name, or 'all' to broadcast to every other agent. "
			.. "Messages are delivered the next time the recipient submits a prompt. "
			.. "Use this to share findings, request help, or coordinate work.",
		inputSchema = {
			type = "object",
			properties = {
				to = {
					type = "string",
					description = "Recipient agent name (e.g. 'researcher') or 'all' for broadcast",
				},
				content = {
					type = "string",
					description = "Message body",
				},
			},
			required = { "to", "content" },
		},
	},

	{
		name = "read_messages",
		description = "Read and clear the pending messages that have been sent to this agent. "
			.. "Call this after processing the messages injected by the context hook to prevent "
			.. "them from being re-injected on the next prompt.",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	{
		name = "update_status",
		description = "Update this agent's status so peer agents know what you are currently working on. "
			.. "Call this at the start of each significant task so colleagues can avoid duplicating work.",
		inputSchema = {
			type = "object",
			properties = {
				current_task = {
					type = "string",
					description = "Short description of what you are currently doing",
				},
			},
			required = { "current_task" },
		},
	},

	{
		name = "list_agent_statuses",
		description = "List the most recent status of all other active agents in this Neovim session. "
			.. "Use this to check what peers are working on before starting a new task.",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	{
		name = "list_agent_roles",
		description = "List the role and expertise of every other active agent. "
			.. "Use this to decide whether to handle a task yourself or delegate it to "
			.. "a peer who is better suited. Each agent's role is set by the user in role.md.",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	-- ----------------------------------------------------------------
	-- Work history tools (persistent across restarts)
	-- ----------------------------------------------------------------

	{
		name = "log_work",
		description = "Append a timestamped entry to your work history file "
			.. "(.nvim-agent/history/<name>.md). Per-agent history files are "
			.. "aggregated by read_cwd_history so all peers can see what every agent has done. "
			.. "Call this after completing any meaningful unit of work "
			.. "(feature implemented, bug fixed, research completed). Be specific — peers and "
			.. "future sessions read this to understand what has been done and why.",
		inputSchema = {
			type = "object",
			properties = {
				summary = {
					type = "string",
					description = "Clear description of what was done and any important decisions made",
				},
			},
			required = { "summary" },
		},
	},

	{
		name = "read_agent_history",
		description = "Read your complete personal work history for this project. "
			.. "Use this when you need to recall exactly what you did in previous sessions.",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	{
		name = "read_cwd_history",
		description = "Read the full shared work history for the current directory — "
			.. "every entry logged by any agent across all sessions. "
			.. "Use this at the start of a new session to orient yourself on past work.",
		inputSchema = {
			type = "object",
			properties = vim.empty_dict(),
			required = {},
		},
	},

	-- ----------------------------------------------------------------
	-- Dynamic agent spawning
	-- ----------------------------------------------------------------

	{
		name = "spawn_agent",
		description = "Dynamically spawn a new workspace agent at runtime. Creates the agent's definition "
			.. "directory, writes its context files (system prompt, role, user notes), creates a session, "
			.. "and opens a terminal buffer. The new agent appears as a peer immediately and can be "
			.. "communicated with via send_message/trigger_agent. Use this when work can be better "
			.. "parallelized by adding more agents on the fly.",
		inputSchema = {
			type = "object",
			properties = {
				name = {
					type = "string",
					description = "Name for the new agent (must be unique among active sessions)",
				},
				system_prompt = {
					type = "string",
					description = "System prompt defining the agent's behavior and responsibilities",
				},
				role = {
					type = "string",
					description = "Short role description for peer discovery (shown to all other agents)",
				},
				user_notes = {
					type = "string",
					description = "User notes with project conventions and constraints for the agent",
				},
			},
			required = { "name", "system_prompt", "role" },
		},
	},
}

------------------------------------------------------------------------
-- Tool list
------------------------------------------------------------------------

function M.list()
	return M.definitions
end

------------------------------------------------------------------------
-- Tool dispatch
------------------------------------------------------------------------

function M.execute(tool_name, arguments)
	arguments = arguments or {}

	-- ----------------------------------------------------------------
	-- read_file
	-- ----------------------------------------------------------------
	if tool_name == "read_file" then
		local filepath = arguments.filepath
		if not filepath then
			return { { type = "text", text = "Error: filepath is required" } }, true
		end

		local result, err = nvim_rpc.read_file(filepath, arguments.start_line, arguments.end_line)
		if err or not result then
			return { { type = "text", text = "Error: " .. (err or "no result from read_file") } }, true
		end

		local lines = {}
		table.insert(
			lines,
			string.format(
				"File: %s (lines %d-%d of %d total)",
				filepath,
				result.start_line,
				result.end_line,
				result.total_lines
			)
		)
		table.insert(lines, "")
		for i, line in ipairs(result.lines) do
			table.insert(lines, string.format("%4d: %s", result.start_line + i - 1, line))
		end

		return { { type = "text", text = table.concat(lines, "\n") } }, false

	-- ----------------------------------------------------------------
	-- edit_buffer
	-- ----------------------------------------------------------------
	elseif tool_name == "edit_buffer" then
		local filepath = arguments.filepath
		local content = arguments.content

		if not filepath then
			return { { type = "text", text = "Error: filepath is required" } }, true
		end
		if content == nil then
			return { { type = "text", text = "Error: content is required (provide file text as a string)" } }, true
		end

		local has_range = arguments.start_line ~= nil and arguments.end_line ~= nil
		local has_partial_range = (arguments.start_line ~= nil) ~= (arguments.end_line ~= nil)

		if has_partial_range then
			return { { type = "text", text = "Error: start_line and end_line must be provided together" } }, true
		end

		if not has_range and not arguments.replace_entire_file then
			return {
				{
					type = "text",
					text = "Error: you must either provide start_line + end_line for a range edit, "
						.. "or set replace_entire_file=true to intentionally replace the whole file. "
						.. "This guard prevents accidental full-file overwrites.",
				},
			},
				true
		end

		local save = arguments.save
		if save == nil then
			save = true
		end
		local review = arguments.review or false

		-- Acquire file lock to prevent concurrent writes from multiple agents
		local lock_ok, lock_err = filelock.acquire(filepath, { agent = AGENT_NAME })
		if not lock_ok then
			return { { type = "text", text = "Error: " .. lock_err } }, true
		end

		local result, err = nvim_rpc.edit_and_focus_buffer(
			filepath,
			content,
			arguments.start_line,
			arguments.end_line,
			save,
			arguments.cursor_line,
			review
		)

		-- Always release lock, even on error
		filelock.release(filepath)

		if err or not result then
			return { { type = "text", text = "Error: " .. (err or "no result from edit_buffer") } }, true
		end

		local msg
		if arguments.start_line and arguments.end_line then
			msg = string.format("Edited '%s' lines %d-%d", filepath, arguments.start_line, arguments.end_line)
		else
			msg = string.format("Edited '%s'", filepath)
		end
		if save then
			msg = msg .. ", saved"
		end
		if review then
			msg = msg .. string.format(" [review: buffer %d left open for user]", result.bufnr)
			if arguments.cursor_line then
				msg = msg .. string.format(", cursor at line %d", arguments.cursor_line)
			end
		else
			msg = msg .. ", buffer closed"
		end

		return { { type = "text", text = msg } }, false

	-- ----------------------------------------------------------------
	-- search_file
	-- ----------------------------------------------------------------
	elseif tool_name == "search_file" then
		local filepath = arguments.filepath
		local pattern = arguments.pattern

		if not filepath then
			return { { type = "text", text = "Error: filepath is required" } }, true
		end
		if not pattern then
			return { { type = "text", text = "Error: pattern is required" } }, true
		end

		local result, err = nvim_rpc.search_in_file(filepath, pattern, arguments.context_lines)
		if err or not result then
			return { { type = "text", text = "Error: " .. (err or "no result from search_file") } }, true
		end

		if #result.matches == 0 then
			return {
				{
					type = "text",
					text = string.format(
						"No matches found for '%s' in %s (%d total lines)",
						pattern,
						filepath,
						result.total_lines
					),
				},
			},
				false
		end

		local lines = {}
		table.insert(
			lines,
			string.format("Found %d match(es) in %s (total lines: %d):", #result.matches, filepath, result.total_lines)
		)

		for i, match in ipairs(result.matches) do
			table.insert(lines, "")
			table.insert(
				lines,
				string.format(
					"Match %d — line %d (use range %d-%d with read_file/edit_buffer):",
					i,
					match.line_number,
					match.start_line,
					match.end_line
				)
			)
			for _, ctx in ipairs(match.context) do
				local marker = ctx.line_number == match.line_number and "> " or "  "
				table.insert(lines, string.format("  %s%4d: %s", marker, ctx.line_number, ctx.content))
			end
		end

		return { { type = "text", text = table.concat(lines, "\n") } }, false

	-- ----------------------------------------------------------------
	-- execute_command
	-- ----------------------------------------------------------------
	elseif tool_name == "execute_command" then
		local command = arguments.command
		if not command then
			return { { type = "text", text = "Error: command is required" } }, true
		end

		local output, err = nvim_rpc.execute_command(command)
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		local text = output ~= "" and output or "(command executed, no output)"
		return { { type = "text", text = text } }, false

	-- ----------------------------------------------------------------
	-- list_buffers
	-- ----------------------------------------------------------------
	elseif tool_name == "list_buffers" then
		local buffers, err = nvim_rpc.list_buffers()
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end
		return { { type = "text", text = json.encode(buffers or {}) } }, false

	-- ----------------------------------------------------------------
	-- get_buffer_content (advanced)
	-- ----------------------------------------------------------------
	elseif tool_name == "get_buffer_content" then
		local bufnr = arguments.bufnr
		if not bufnr then
			return { { type = "text", text = "Error: bufnr is required" } }, true
		end

		local lines, err = nvim_rpc.get_buffer_content(bufnr)
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		return { { type = "text", text = table.concat(lines or {}, "\n") } }, false

	-- ----------------------------------------------------------------
	-- set_buffer_content (advanced)
	-- ----------------------------------------------------------------
	elseif tool_name == "set_buffer_content" then
		local bufnr = arguments.bufnr
		local lines = arguments.lines

		if not bufnr then
			return { { type = "text", text = "Error: bufnr is required" } }, true
		end
		if not lines or type(lines) ~= "table" then
			return { { type = "text", text = "Error: lines must be an array of strings" } }, true
		end

		local _, err = nvim_rpc.set_buffer_content(bufnr, lines)
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		return { { type = "text", text = string.format("Buffer %d content updated (not saved)", bufnr) } }, false

	-- ----------------------------------------------------------------
	-- open_buffer
	-- ----------------------------------------------------------------
	elseif tool_name == "open_buffer" then
		local filepath = arguments.filepath
		if not filepath then
			return { { type = "text", text = "Error: filepath is required" } }, true
		end

		local bufnr, err = nvim_rpc.open_buffer(filepath)
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		return { { type = "text", text = string.format("Opened '%s' in buffer %d", filepath, bufnr or 0) } }, false

	-- ----------------------------------------------------------------
	-- close_buffer
	-- ----------------------------------------------------------------
	elseif tool_name == "close_buffer" then
		local bufnr = arguments.bufnr
		if not bufnr then
			return { { type = "text", text = "Error: bufnr is required" } }, true
		end

		local _, err = nvim_rpc.close_buffer(bufnr, arguments.force)
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		return { { type = "text", text = string.format("Buffer %d closed", bufnr) } }, false

	-- ----------------------------------------------------------------
	-- set_cursor
	-- ----------------------------------------------------------------
	elseif tool_name == "set_cursor" then
		local row = arguments.row
		local col = arguments.col

		if not row or not col then
			return { { type = "text", text = "Error: row and col are required" } }, true
		end

		local _, err = nvim_rpc.set_cursor(row, col)
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		return { { type = "text", text = string.format("Cursor moved to row %d, col %d", row, col) } }, false

	-- ----------------------------------------------------------------
	-- get_cursor
	-- ----------------------------------------------------------------
	elseif tool_name == "get_cursor" then
		local cursor, err = nvim_rpc.get_cursor()
		if err then
			return { { type = "text", text = "Error: " .. err } }, true
		end

		return { { type = "text", text = json.encode(cursor or {}) } }, false

	-- ----------------------------------------------------------------
	-- trigger_agent  (deliver message + wake terminal immediately)
	-- ----------------------------------------------------------------
	elseif tool_name == "trigger_agent" then
		local to = arguments.to
		local message = arguments.message

		if not to or to == "" then
			return { { type = "text", text = "Error: 'to' is required" } }, true
		end
		if not message or message == "" then
			return { { type = "text", text = "Error: 'message' is required" } }, true
		end
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		-- 1. Deliver message to mailbox
		local ok, deliver_err = deliver_message(to, AGENT_NAME, message)
		if not ok then
			return { { type = "text", text = "Error delivering message: " .. (deliver_err or "?") } }, true
		end

		-- 2. Write trigger file so the continuation timer can also find it.
		--    Locked because the timer truncates this same file when it fires.
		local trigger_dir = CWD .. "/.nvim-agent/triggers"
		os.execute("mkdir -p " .. trigger_dir)
		local trigger_path = trigger_dir .. "/" .. to .. ".md"
		with_lock(trigger_path, function()
			local tf = io.open(trigger_path, "a")
			if tf then
				tf:write(string.format("\n[%s] Triggered by %s\n", os.date("%Y-%m-%d %H:%M:%S"), AGENT_NAME))
				tf:close()
			end
		end)

		-- 3. Wake the recipient's terminal via Neovim RPC
		local wakeup = "You have a new message from "
			.. AGENT_NAME
			.. ". Please check your context and begin working on it.\r"
		local _, rpc_err = nvim_rpc.trigger_agent(to, wakeup)
		if rpc_err then
			-- Delivered but terminal wake failed (agent may not be running yet)
			return {
				{
					type = "text",
					text = string.format(
						"Message delivered to '%s' but terminal wake failed: %s\n"
							.. "(The agent will see the message on their next prompt.)",
						to,
						rpc_err
					),
				},
			},
				false
		end

		return {
			{ type = "text", text = string.format("Agent '%s' triggered: message delivered and terminal woken.", to) },
		},
			false

	-- ----------------------------------------------------------------
	-- send_message
	-- ----------------------------------------------------------------
	elseif tool_name == "send_message" then
		local to = arguments.to
		local content = arguments.content

		if not to or to == "" then
			return { { type = "text", text = "Error: 'to' is required (agent name or 'all')" } }, true
		end
		if not content or content == "" then
			return { { type = "text", text = "Error: 'content' is required" } }, true
		end
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		-- Helper: deliver + write trigger file + attempt immediate wakeup.
		-- Returns true on success, or false + error string on delivery failure.
		local function deliver_and_wake(recipient)
			local ok, err = deliver_message(recipient, AGENT_NAME, content)
			if not ok then
				return false, err
			end
			-- Write trigger file so the continuation timer wakes the agent within 30 s
			-- even if the RPC wakeup below fails. Locked: the timer truncates this file.
			local trigger_dir = CWD .. "/.nvim-agent/triggers"
			os.execute("mkdir -p " .. trigger_dir)
			local trigger_path = trigger_dir .. "/" .. recipient .. ".md"
			with_lock(trigger_path, function()
				local tf = io.open(trigger_path, "a")
				if tf then
					tf:write(string.format("\n[%s] Message from %s\n", os.date("%Y-%m-%d %H:%M:%S"), AGENT_NAME))
					tf:close()
				end
			end)
			-- Best-effort immediate wakeup (non-fatal on failure).
			local wakeup = "You have a new message from "
				.. AGENT_NAME
				.. ". Please check your context and begin working on it.\r"
			nvim_rpc.trigger_agent(recipient, wakeup)
			return true
		end

		if to == "all" then
			local peers = list_peer_names()
			if #peers == 0 then
				return { { type = "text", text = "No other agents found to message" } }, false
			end
			local errors = {}
			for _, peer in ipairs(peers) do
				local ok, err = deliver_and_wake(peer)
				if not ok then
					table.insert(errors, peer .. ": " .. (err or "unknown"))
				end
			end
			local msg = string.format("Broadcast sent to %d agent(s): %s", #peers, table.concat(peers, ", "))
			if #errors > 0 then
				msg = msg .. "\nDelivery errors: " .. table.concat(errors, "; ")
			end
			return { { type = "text", text = msg } }, false
		else
			local ok, err = deliver_and_wake(to)
			if not ok then
				return { { type = "text", text = "Error: " .. (err or "delivery failed") } }, true
			end
			return { { type = "text", text = string.format("Message sent to '%s'", to) } }, false
		end

	-- ----------------------------------------------------------------
	-- read_messages  (reads and clears this agent's mailbox)
	-- ----------------------------------------------------------------
	elseif tool_name == "read_messages" then
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		local path = project_comm_dir("messages") .. "/" .. AGENT_NAME .. ".md"
		-- Hold the mailbox lock for the entire read+truncate so a concurrent
		-- deliver_message cannot land between the two ops and get silently
		-- erased.
		local content, lock_err = with_lock(path, function()
			local f = io.open(path, "r")
			if not f then
				return nil
			end
			local data = f:read("*a")
			f:close()
			-- Clear the mailbox so the hook does not re-inject the same messages
			local fw = io.open(path, "w")
			if fw then
				fw:close()
			end
			return data
		end)
		if lock_err then
			return { { type = "text", text = "Error: " .. lock_err } }, true
		end

		if not content or content:match("^%s*$") then
			return { { type = "text", text = "No pending messages" } }, false
		end

		return { { type = "text", text = content } }, false

	-- ----------------------------------------------------------------
	-- update_status  (also reads role.md from active_dir so peers see it)
	-- ----------------------------------------------------------------
	elseif tool_name == "update_status" then
		local current_task = arguments.current_task
		if not current_task or current_task == "" then
			return { { type = "text", text = "Error: 'current_task' is required" } }, true
		end
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		local status_dir = project_comm_dir("status")
		os.execute("mkdir -p " .. status_dir)

		-- Include the agent's current role so peers can discover it without a separate file
		local role = nil
		if ACTIVE_DIR ~= "" then
			role = read_file_contents(ACTIVE_DIR .. "/role.md")
			if role and role:match("^%s*$") then
				role = nil
			end
		end

		local status = {
			agent = AGENT_NAME,
			current_task = current_task,
			role = role,
			updated_at = os.date("%Y-%m-%dT%H:%M:%SZ"),
		}

		local path = status_dir .. "/" .. AGENT_NAME .. ".json"
		-- Lock + atomic rename: lock serializes against the parent Neovim's
		-- initial-status writer (init.lua workspace_launch); atomic rename
		-- keeps concurrent readers from seeing a half-written file.
		local ok, err = with_lock(path, function()
			local wok, werr = atomic_write(path, json.encode(status))
			if not wok then
				error(werr)
			end
			return true
		end)
		if not ok then
			return { { type = "text", text = "Error: " .. tostring(err) } }, true
		end

		return { { type = "text", text = string.format("Status updated: %s", current_task) } }, false

	-- ----------------------------------------------------------------
	-- list_agent_statuses
	-- ----------------------------------------------------------------
	elseif tool_name == "list_agent_statuses" then
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		local peers = list_peer_names()
		if #peers == 0 then
			return { { type = "text", text = "No other agents found in .nvim-agent/status/" } }, false
		end

		local lines = {}
		for _, peer in ipairs(peers) do
			local path = project_comm_dir("status") .. "/" .. peer .. ".json"
			local f = io.open(path, "r")
			if f then
				local raw = f:read("*a")
				f:close()
				local ok, data = pcall(json.decode, raw)
				if ok and type(data) == "table" then
					table.insert(
						lines,
						string.format(
							"  %s — %s  (updated: %s)",
							data.agent or peer,
							data.current_task or "(no status)",
							data.updated_at or "?"
						)
					)
				else
					table.insert(lines, string.format("  %s — (unreadable status)", peer))
				end
			else
				table.insert(lines, string.format("  %s — (no status yet)", peer))
			end
		end

		return { { type = "text", text = "Peer agent statuses:\n" .. table.concat(lines, "\n") } }, false

	-- ----------------------------------------------------------------
	-- list_agent_roles  (reads role field from each agent's status file)
	-- ----------------------------------------------------------------
	elseif tool_name == "list_agent_roles" then
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		local peers = list_peer_names()
		if #peers == 0 then
			return { { type = "text", text = "No other agents found in .nvim-agent/status/" } }, false
		end

		local lines = {}
		for _, peer in ipairs(peers) do
			local path = project_comm_dir("status") .. "/" .. peer .. ".json"
			local f = io.open(path, "r")
			local role_text = nil
			if f then
				local raw = f:read("*a")
				f:close()
				local ok, data = pcall(json.decode, raw)
				if ok and type(data) == "table" and data.role and data.role ~= "" then
					role_text = data.role
				end
			end
			table.insert(lines, string.format("## Agent: %s\n%s", peer, role_text or "(no role defined)"))
		end

		return { { type = "text", text = table.concat(lines, "\n\n") } }, false

	-- ----------------------------------------------------------------
	-- log_work
	-- ----------------------------------------------------------------
	elseif tool_name == "log_work" then
		local summary = arguments.summary
		if not summary or summary == "" then
			return { { type = "text", text = "Error: 'summary' is required" } }, true
		end
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set — cannot locate project history" } }, true
		end

		-- Write to .nvim-agent/history/<agent>.md inside the project directory
		local hist_dir = CWD .. "/.nvim-agent/history"
		os.execute("mkdir -p " .. hist_dir)
		local hist_path = hist_dir .. "/" .. AGENT_NAME .. ".md"
		local ok = append_history(hist_path, AGENT_NAME, summary)

		if ok then
			return { { type = "text", text = "Work logged to " .. hist_path } }, false
		else
			return { { type = "text", text = "Warning: could not write to " .. hist_path } }, false
		end

	-- ----------------------------------------------------------------
	-- read_agent_history
	-- ----------------------------------------------------------------
	elseif tool_name == "read_agent_history" then
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		local path = CWD .. "/.nvim-agent/history/" .. AGENT_NAME .. ".md"
		local content = read_file_contents(path)
		if not content or content:match("^%s*$") then
			return {
				{ type = "text", text = "No work history recorded yet for '" .. AGENT_NAME .. "' in this project" },
			},
				false
		end
		return { { type = "text", text = content } }, false

	-- ----------------------------------------------------------------
	-- read_cwd_history  (reads all agents' history for this project)
	-- ----------------------------------------------------------------
	elseif tool_name == "read_cwd_history" then
		if CWD == "" then
			return { { type = "text", text = "Error: NVIM_AGENT_CWD not set" } }, true
		end

		local hist_dir = CWD .. "/.nvim-agent/history"
		local handle = io.popen('ls "' .. hist_dir .. '"/*.md 2>/dev/null')
		if not handle then
			return { { type = "text", text = "No project history found" } }, false
		end

		local parts = {}
		for path in handle:lines() do
			local agent_name = path:match("/([^/]+)%.md$") or "?"
			local content = read_file_contents(path)
			if content and not content:match("^%s*$") then
				table.insert(parts, "### " .. agent_name .. "\n" .. content)
			end
		end
		handle:close()

		if #parts == 0 then
			return { { type = "text", text = "No project history recorded yet" } }, false
		end
		return { { type = "text", text = table.concat(parts, "\n\n") } }, false

	-- ----------------------------------------------------------------
	-- spawn_agent  (dynamically create a new workspace agent at runtime)
	-- ----------------------------------------------------------------
	elseif tool_name == "spawn_agent" then
		local name = arguments.name
		local system_prompt = arguments.system_prompt
		local role_text = arguments.role
		local notes = arguments.user_notes or ""

		if not name or name == "" then
			return { { type = "text", text = "Error: 'name' is required" } }, true
		end
		if not system_prompt or system_prompt == "" then
			return { { type = "text", text = "Error: 'system_prompt' is required" } }, true
		end
		if not role_text or role_text == "" then
			return { { type = "text", text = "Error: 'role' is required" } }, true
		end

		local ok, err = nvim_rpc.spawn_agent(name, system_prompt, role_text, notes)
		if not ok then
			return { { type = "text", text = "Error spawning agent: " .. (err or "unknown") } }, true
		end

		return {
			{
				type = "text",
				text = string.format(
					"Agent '%s' spawned successfully. Role: %s\n\nUse trigger_agent('%s', ...) to send it work.",
					name,
					role_text,
					name
				),
			},
		},
			false
	else
		return { { type = "text", text = "Error: Unknown tool: " .. tool_name } }, true
	end
end

return M
