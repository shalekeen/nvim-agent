local adapter_base = require("nvim-agent.adapter")
local config = require("nvim-agent.config")

local M = adapter_base.new({})

------------------------------------------------------------------------
-- Permission profiles
--
-- Named profiles define which Claude Code tools an agent is allowed to use.
-- Agents declare their profile via a "permissions.json" file in their
-- definition directory, or via a "permissions" field in the workspace JSON.
--
-- Format of permissions.json:
--   { "profile": "<name>" }                — use a named profile
--   { "allow": [...], "deny": [...] }      — custom allow/deny lists
--
-- Available profiles:
--   "full"      — all tools (default for agents without a permissions file)
--   "read-only" — can read code, search, run non-destructive commands; no writes
--   "no-code"   — cannot read or write code; can only use agent communication tools
------------------------------------------------------------------------

local PERMISSION_PROFILES = {
	-- Full access: can read, write, execute, and use all MCP tools.
	-- For: Senior SWEs, Junior SWEs
	["full"] = {
		allow = {
			"Bash(*)",
			"Read(*)",
			"Write(*)",
			"Edit(*)",
			"Glob(*)",
			"Grep(*)",
			"mcp__nvim-agent__*",
		},
		deny = {},
	},

	-- QA: can read all code, search, run builds/tests, and write test files.
	-- Cannot use MCP edit tools to modify editor buffers directly.
	-- For: QA engineers
	["qa"] = {
		allow = {
			"Bash(*)",
			"Read(*)",
			"Write(*)",
			"Edit(*)",
			"Glob(*)",
			"Grep(*)",
			"mcp__nvim-agent__read_file",
			"mcp__nvim-agent__search_file",
			"mcp__nvim-agent__list_buffers",
			"mcp__nvim-agent__get_buffer_content",
			"mcp__nvim-agent__get_cursor",
			"mcp__nvim-agent__execute_command",
			"mcp__nvim-agent__send_message",
			"mcp__nvim-agent__read_messages",
			"mcp__nvim-agent__update_status",
			"mcp__nvim-agent__list_agent_statuses",
			"mcp__nvim-agent__list_agent_roles",
			"mcp__nvim-agent__log_work",
			"mcp__nvim-agent__read_agent_history",
			"mcp__nvim-agent__read_cwd_history",
			"mcp__nvim-agent__trigger_agent",
		},
		deny = {},
	},

	-- Oversight: can read docs/specs/output, search the codebase, run read-only
	-- commands, and communicate with all agents — but cannot write or edit files.
	-- For: Product Managers, CEOs, stakeholders
	["oversight"] = {
		allow = {
			"Read(*)",
			"Glob(*)",
			"Grep(*)",
			"mcp__nvim-agent__read_file",
			"mcp__nvim-agent__search_file",
			"mcp__nvim-agent__list_buffers",
			"mcp__nvim-agent__get_buffer_content",
			"mcp__nvim-agent__execute_command",
			"mcp__nvim-agent__send_message",
			"mcp__nvim-agent__read_messages",
			"mcp__nvim-agent__update_status",
			"mcp__nvim-agent__list_agent_statuses",
			"mcp__nvim-agent__list_agent_roles",
			"mcp__nvim-agent__log_work",
			"mcp__nvim-agent__read_agent_history",
			"mcp__nvim-agent__read_cwd_history",
			"mcp__nvim-agent__trigger_agent",
		},
		deny = {},
	},

	-- Orchestrator: same as oversight plus spawn_agent for dynamic scaling.
	-- For: RoboResources, resource managers
	["orchestrator"] = {
		allow = {
			"Read(*)",
			"Glob(*)",
			"Grep(*)",
			"mcp__nvim-agent__read_file",
			"mcp__nvim-agent__search_file",
			"mcp__nvim-agent__list_buffers",
			"mcp__nvim-agent__get_buffer_content",
			"mcp__nvim-agent__execute_command",
			"mcp__nvim-agent__send_message",
			"mcp__nvim-agent__read_messages",
			"mcp__nvim-agent__update_status",
			"mcp__nvim-agent__list_agent_statuses",
			"mcp__nvim-agent__list_agent_roles",
			"mcp__nvim-agent__log_work",
			"mcp__nvim-agent__read_agent_history",
			"mcp__nvim-agent__read_cwd_history",
			"mcp__nvim-agent__trigger_agent",
			"mcp__nvim-agent__spawn_agent",
		},
		deny = {},
	},
}

-- Backward compatibility: old profile names map to new ones
PERMISSION_PROFILES["read-only"] = PERMISSION_PROFILES["qa"]
PERMISSION_PROFILES["no-code"] = PERMISSION_PROFILES["oversight"]

--- Resolve permissions for an agent. Checks (in order):
---   1. permissions.json in the agent's definition directory
---   2. Default "full" profile
--- @param agent_name string
--- @param cwd string|nil
--- @return table  { allow: string[], deny: string[] }
function M:get_agent_permissions(agent_name, cwd)
	cwd = cwd or vim.fn.getcwd()
	local workspace_mod = require("nvim-agent.workspace")

	-- Try to read permissions.json from the agent's definition directory
	local def_dir = workspace_mod.agent_content_dir(agent_name, cwd)
	if def_dir then
		local perm_path = def_dir .. "/permissions.json"
		local f = io.open(perm_path, "r")
		if f then
			local content = f:read("*a")
			f:close()
			local ok, data = pcall(vim.json.decode, content)
			if ok and type(data) == "table" then
				-- If it specifies a named profile, use that
				if data.profile and PERMISSION_PROFILES[data.profile] then
					return PERMISSION_PROFILES[data.profile]
				end
				-- Otherwise treat it as a custom allow/deny spec
				if data.allow then
					return {
						allow = data.allow,
						deny = data.deny or {},
					}
				end
			end
		end
	end

	-- Default: full permissions
	return PERMISSION_PROFILES["full"]
end

local function hook_script_path()
	local base_dir = config.get().base_dir or vim.fn.expand("~/.nvim-agent")
	return base_dir .. "/hooks/claude_code_prompt.sh"
end

--- Read the system prompt content from the given active_dir.
local function read_system_prompt(active_dir)
	local path = active_dir .. "/system_prompt.md"
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content ~= "" and content or nil
end

function M:get_cmd(session)
	if not session then
		vim.notify("nvim-agent: get_cmd called without a session", vim.log.levels.ERROR)
		return { "claude" }
	end
	local active_dir = session.active_dir
	local debug_log = vim.fn.expand("~/.nvim-agent/claude-mcp-debug.log")

	-- Read system prompt from the session's active directory
	local prompt = read_system_prompt(active_dir) or self:get_system_prompt()

	-- Determine MCP config: per-session file if session given, else global settings
	local mcp_config
	if session then
		mcp_config = session.dir .. "/mcp-settings.json"
	else
		mcp_config = vim.fn.expand("~/.claude/settings.json")
	end

	local cmd = {
		"claude",
		"--system-prompt",
		prompt,
		"--debug-file",
		debug_log,
	}

	if vim.fn.filereadable(mcp_config) == 1 then
		table.insert(cmd, "--mcp-config")
		table.insert(cmd, mcp_config)
	end

	-- Apply per-agent tool permissions via --allowedTools
	local perms = self:get_agent_permissions(session.name, vim.fn.getcwd())
	if perms and perms.allow and #perms.allow > 0 then
		table.insert(cmd, "--allowedTools")
		for _, tool in ipairs(perms.allow) do
			table.insert(cmd, tool)
		end
	end

	return cmd
end

--- Write a per-session MCP settings file at session.dir/mcp-settings.json.
--- Includes the nvim-agent MCP server with session-specific env vars
--- and the UserPromptSubmit hook.
function M:setup_session_mcp(session)
	vim.fn.system("which luajit 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		vim.notify(
			"nvim-agent: luajit not found. Per-session MCP not configured for session " .. session.id,
			vim.log.levels.WARN
		)
		return
	end

	local nvim_address = vim.v.servername
	if not nvim_address or nvim_address == "" then
		vim.notify(
			"nvim-agent: could not determine Neovim socket. Per-session MCP not configured.",
			vim.log.levels.WARN
		)
		return
	end

	local mcp_server_path = vim.api.nvim_get_runtime_file("lua/nvim-agent/mcp/server.lua", false)[1]
	if not mcp_server_path or not vim.loop.fs_stat(mcp_server_path) then
		vim.notify("nvim-agent: MCP server script not found on runtimepath (lua/nvim-agent/mcp/server.lua)", vim.log.levels.WARN)
		return
	end

	local settings = {
		mcpServers = {
			["nvim-agent"] = {
				command = "luajit",
				args = { mcp_server_path },
				env = {
					NVIM_LISTEN_ADDRESS = nvim_address,
					NVIM_AGENT_ACTIVE_DIR = session.active_dir,
					NVIM_AGENT_PROCESS_DIR = session.process_dir,
					NVIM_AGENT_CWD = vim.fn.getcwd(),
					NVIM_AGENT_BASE_DIR = config.get().base_dir,
				},
			},
		},
		hooks = {
			UserPromptSubmit = {
				{
					hooks = {
						{
							type = "command",
							command = hook_script_path(),
						},
					},
				},
			},
		},
	}

	local path = session.dir .. "/mcp-settings.json"
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local fw = io.open(path, "w")
	if not fw then
		vim.notify("nvim-agent: failed to write " .. path, vim.log.levels.ERROR)
		return
	end
	fw:write(vim.json.encode(settings))
	fw:close()
end

--- Build the hook shell script content.
local function hook_script_content()
	return [[#!/usr/bin/env bash
ACTIVE_DIR="${NVIM_AGENT_ACTIVE_DIR}"
PROCESS_DIR="${NVIM_AGENT_PROCESS_DIR}"
CWD="${NVIM_AGENT_CWD}"
if [ -z "$ACTIVE_DIR" ]; then
    echo "nvim-agent: NVIM_AGENT_ACTIVE_DIR not set (not running inside nvim-agent?)" >&2
    exit 0
fi

# Derive this session's name from the active dir path:
#   .../sessions/<pid>/<name>/active  →  <name>
SESSION_NAME=$(basename "$(dirname "$ACTIVE_DIR")")

echo "🚨 REMINDER: Use MCP tools for ALL file operations: read_file to read, edit_buffer to write, search_file to find code. DO NOT use built-in Read/Write/Edit tools."
echo ""
echo "=== NEOVIM EDITOR CONTEXT ==="

# Session-specific files (flavor, notes, dirs, role)
for f in .flavor_meta.json user_notes.md persistent_dirs.json role.md; do
    if [ -f "$ACTIVE_DIR/$f" ]; then
        echo "--- $f ---"
        cat "$ACTIVE_DIR/$f"
        echo ""
    fi
done

# Project context file (PROJECT.md at project root — shared by all agents)
if [ -n "$CWD" ] && [ -f "$CWD/PROJECT.md" ]; then
    echo "--- PROJECT.md ---"
    cat "$CWD/PROJECT.md"
    echo ""
fi

# Ephemeral context (Neovim process state: open buffers, diagnostics, cursor)
if [ -n "$PROCESS_DIR" ] && [ -f "$PROCESS_DIR/ephemeral.json" ]; then
    echo "--- ephemeral.json ---"
    cat "$PROCESS_DIR/ephemeral.json"
    echo ""
fi

# Tmux pane captures
if [ -n "$PROCESS_DIR" ] && [ -f "$PROCESS_DIR/tmux_captures.json" ]; then
    echo "--- tmux_captures.json ---"
    cat "$PROCESS_DIR/tmux_captures.json"
    echo ""
fi

# All project-level communication lives in $CWD/.nvim-agent/
if [ -n "$CWD" ] && [ -n "$SESSION_NAME" ]; then
    PROJ_DIR="$CWD/.nvim-agent"

    # Pending messages addressed to this agent
    MSG_FILE="$PROJ_DIR/messages/$SESSION_NAME.md"
    if [ -s "$MSG_FILE" ]; then
        echo "--- messages_for_you.md ---"
        cat "$MSG_FILE"
        echo "(Call the read_messages MCP tool after processing to clear these)"
        echo ""
    fi

    # Status and role of all peer agents (from .nvim-agent/status/*.json)
    FOUND_PEER=false
    for status_file in "$PROJ_DIR/status/"*.json; do
        [ -f "$status_file" ] || continue
        peer_name=$(basename "$status_file" .json)
        [ "$peer_name" = "$SESSION_NAME" ] && continue
        if [ "$FOUND_PEER" = "false" ]; then
            echo "--- peer_agents ---"
            FOUND_PEER=true
        fi
        # Parse the JSON fields we care about with grep/sed (no jq dependency)
        task=$(grep -o '"current_task":"[^"]*"' "$status_file" 2>/dev/null | sed 's/"current_task":"//;s/"//')
        role=$(grep -o '"role":"[^"]*"' "$status_file" 2>/dev/null | sed 's/"role":"//;s/"//')
        updated=$(grep -o '"updated_at":"[^"]*"' "$status_file" 2>/dev/null | sed 's/"updated_at":"//;s/"//')
        printf "Agent: %s\n" "$peer_name"
        [ -n "$role" ] && printf "Role: %s\n" "$role"
        [ -n "$task" ] && printf "Status: %s  (at %s)\n" "$task" "$updated"
        echo ""
    done
    if [ "$FOUND_PEER" = "true" ]; then
        echo ""
    fi

    # Project-local work history (persistent across nvim restarts)
    PROJ_HIST="$PROJ_DIR/history/$SESSION_NAME.md"
    if [ -s "$PROJ_HIST" ]; then
        echo "--- agent_history.md (last 40 lines) ---"
        tail -40 "$PROJ_HIST"
        echo ""
    fi
fi

echo "=== END NEOVIM CONTEXT ==="
]]
end

--- Build the CLAUDE.md instruction block content.
local function claude_md_content()
	return [[You are working inside Neovim via the nvim-agent plugin.

Context is split across three directories:
- Session dir  ($NVIM_AGENT_ACTIVE_DIR):  ~/.nvim-agent/sessions/<pid>/<name>/active/
- Process dir  ($NVIM_AGENT_PROCESS_DIR): ~/.nvim-agent/sessions/<pid>/
- Project dir  ($NVIM_AGENT_CWD/.nvim-agent/): project-local data (persists across restarts)

A UserPromptSubmit hook automatically injects these context files before each prompt:
- .flavor_meta.json           -- (session dir) Your active flavor and checkpoint
- user_notes.md               -- (session dir) User preferences and constraints
- persistent_dirs.json        -- (session dir) Important code paths to reference
- role.md                     -- (session dir) Your role and area of expertise (if set)
- PROJECT.md                  -- (project root) Project vision, architecture, and conventions (if present)
- ephemeral.json              -- (process dir) Current editor state, SHARED by all agents
- tmux_captures.json          -- (process dir) Captured tmux pane content, SHARED by all agents
- messages_for_you.md         -- (project dir) Pending messages from peer agents (if any)
- peer_agents                 -- (project dir) Role + status of each other active agent (if any)
- agent_history.md            -- (project dir) Last 40 lines of YOUR work history (if any)

ephemeral.json is refreshed every time the user switches to any agent terminal buffer.
Project-dir files persist across Neovim restarts.

## ⚠️ CRITICAL: File Operations MUST Use MCP Tools ⚠️

DO NOT use the built-in Read, Write, Edit, or Bash file tools. Use the MCP tools below.
The MCP tools update the user's Neovim buffers in real-time. Built-in tools bypass the editor.

If you don't see MCP tools in your tool list, notify the user that the MCP server may not be connected.

---

## Primary MCP Tools

### 1. read_file — read a file from disk
Parameters:
- filepath (required): absolute path
- start_line (optional): first line to read, 1-indexed
- end_line (optional): last line to read, 1-indexed inclusive

Examples:
  read_file(filepath="/path/to/file.py")
  read_file(filepath="/path/to/file.py", start_line=10, end_line=50)

### 2. edit_buffer — create or edit a file
Parameters:
- filepath (required): absolute path (file is created if it doesn't exist)
- content (required): the new file content as a plain string
- start_line + end_line (provide both for a range edit, 1-indexed inclusive)
- replace_entire_file (set true to intentionally replace the whole file)
- save (optional): save after editing, default true
- cursor_line (optional): line to position cursor on after editing

You MUST provide either start_line+end_line OR replace_entire_file=true.
Omitting both is an error — this prevents accidental full-file overwrites.

Examples:
  -- Range edit (preferred for existing files):
  edit_buffer(filepath="/path/to/file.py", content="    return 42\n", start_line=15, end_line=15)

  -- Full file replacement (new files or intentional rewrites):
  edit_buffer(filepath="/path/to/file.py", content="def hello():\n    print('Hello!')\n", replace_entire_file=true)

### 3. search_file — find code in a file
Parameters:
- filepath (required): absolute path
- pattern (required): Lua pattern to search for (similar to regex)
- context_lines (optional): lines of context around each match, default 0

Returns matches with their line numbers and a suggested range for read_file/edit_buffer.

Examples:
  search_file(filepath="/path/to/file.py", pattern="def handleFoo")
  search_file(filepath="/path/to/file.py", pattern="TODO", context_lines=3)

### 4. execute_command — run a Neovim ex command (returns output)
  execute_command(command="w")
  execute_command(command="set number")

### 5. list_buffers — list open file buffers
Returns buffer numbers, paths, modified status, and filetypes.

---

## Recommended Workflow for Targeted Edits

1. Find the code location:
   search_file(filepath="...", pattern="function handleFoo", context_lines=5)

2. Read just that section:
   read_file(filepath="...", start_line=42, end_line=60)

3. Edit only that section:
   edit_buffer(filepath="...", content="...", start_line=42, end_line=60)

This avoids reading or rewriting entire large files.
For new files: edit_buffer(filepath="...", content="...", replace_entire_file=true)

---

## Advanced Tools (buffer-number based)

- get_buffer_content(bufnr): read in-memory buffer state (may include unsaved changes)
- set_buffer_content(bufnr, lines): write to buffer without saving; lines is an array of strings
- open_buffer(filepath): open a file in the editor window (switches user's view)
- close_buffer(bufnr, force): close a buffer; force=true discards unsaved changes
- set_cursor(row, col) / get_cursor(): cursor control

---

## Agent Communication Tools

When running in multi-agent mode (multiple sessions in the same Neovim process), peer agents
are visible in the injected peer_agents context. Use these tools to coordinate.

### send_message(to, content)
Send a message to a peer agent by name, or "all" to broadcast to every other agent.
Messages are delivered the next time the recipient submits a prompt.

### read_messages()
Read and clear your pending mailbox. IMPORTANT: call this after processing injected
messages_for_you.md so the same messages are not re-injected on the next prompt.

### update_status(current_task)
Announce what you are currently working on. All peers see this before every prompt.

### list_agent_statuses()
Get the latest status of every other active agent.

### list_agent_roles()
Get the role/expertise description of every other active agent. Use this to decide
whether a task should be delegated to a more appropriate peer.

---

## Work History Tools

History is written to disk and persists across Neovim restarts. The hook injects a
recent excerpt before each prompt so you always have context on past work.

### log_work(summary)
Append a timestamped entry to your work history file (.nvim-agent/history/<name>.md).
This file is included in the output of read_cwd_history so all peers can see what you did.
Call this after completing a meaningful unit of work: implementing a feature, fixing a
bug, completing a research spike, etc. Be specific — future-you and peer agents will
rely on these entries to understand what was done and avoid duplicate work.

### read_agent_history()
Read your complete personal work history for this project.

### read_cwd_history()
Read the full shared history of all work done in the current directory by any agent.
Use this when starting a new session to understand what has already been accomplished.

### spawn_agent(name, system_prompt, role, user_notes)
Dynamically spawn a new workspace agent at runtime. Creates the agent's definition
directory, writes context files, creates a session, and opens a terminal buffer.
The new agent appears as a peer immediately and can be communicated with via
send_message/trigger_agent. Use this when work can be better parallelized by adding
more agents on the fly.

---

## Coordination Guidelines

- When you start a new session, call read_cwd_history() to orient yourself.
- Before starting a task, call list_agent_roles() and list_agent_statuses() to check
  whether a peer is better suited for it or is already working on it.
- After meaningful work, call log_work() with a clear summary.
- When you receive messages in injected context, call read_messages() to clear them.
- If a task falls outside your role, use send_message() to delegate it to the right peer.]]
end

--- Write the hook script to ~/.nvim-agent/hooks/claude_code_prompt.sh
local function write_hook_script()
	local path = hook_script_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

	local f = io.open(path, "w")
	if not f then
		vim.notify("nvim-agent: failed to write hook script: " .. path, vim.log.levels.ERROR)
		return false
	end
	f:write(hook_script_content())
	f:close()

	vim.fn.system("chmod +x " .. vim.fn.shellescape(path))
	return true
end

--- Update ~/.claude/settings.json to add the UserPromptSubmit hook.
--- Also ensures NVIM_AGENT_ACTIVE_DIR is set in the global MCP entry
--- (defaults to session 1's active dir for backward compat).
local function write_claude_settings()
	local settings_dir = vim.fn.expand("~/.claude")
	local settings_path = settings_dir .. "/settings.json"

	vim.fn.mkdir(settings_dir, "p")

	-- Read existing settings
	local existing = {}
	local f = io.open(settings_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, data = pcall(vim.json.decode, content)
			if ok and type(data) == "table" then
				existing = data
			end
		end
	end

	-- Add hook if missing
	if not (existing.hooks and existing.hooks.UserPromptSubmit) then
		existing.hooks = existing.hooks or {}
		existing.hooks.UserPromptSubmit = {
			{
				hooks = {
					{
						type = "command",
						command = hook_script_path(),
					},
				},
			},
		}
	end

	local fw = io.open(settings_path, "w")
	if not fw then
		vim.notify("nvim-agent: failed to write " .. settings_path, vim.log.levels.ERROR)
		return
	end
	fw:write(vim.json.encode(existing))
	fw:close()
end

--- Write the nvim-agent block to ~/.claude/CLAUDE.md using markers
--- for idempotent updates.
local function write_claude_md()
	local claude_md_path = vim.fn.expand("~/.claude/CLAUDE.md")
	vim.fn.mkdir(vim.fn.fnamemodify(claude_md_path, ":h"), "p")

	local marker_start = "<!-- nvim-agent:start -->"
	local marker_end = "<!-- nvim-agent:end -->"
	local block = marker_start .. "\n" .. claude_md_content() .. "\n" .. marker_end

	-- Read existing content
	local f = io.open(claude_md_path, "r")
	local existing = ""
	if f then
		existing = f:read("*a")
		f:close()
	end

	local new_content
	if existing:find(marker_start, 1, true) then
		-- Replace existing nvim-agent block
		local pattern = vim.pesc(marker_start) .. ".-" .. vim.pesc(marker_end)
		new_content = existing:gsub(pattern, function()
			return block
		end)
	elseif existing ~= "" then
		new_content = existing .. "\n\n" .. block
	else
		new_content = block
	end

	local fw = io.open(claude_md_path, "w")
	if not fw then
		vim.notify("nvim-agent: failed to write " .. claude_md_path, vim.log.levels.ERROR)
		return
	end
	fw:write(new_content)
	fw:close()
end

--- Write <cwd>/.claude/settings.json with broad allow-permissions so Claude Code
--- agents don't pause to ask for confirmation on every file/bash operation.
--- Safe to call repeatedly — merges with any existing project settings.
--- @param cwd string  Project directory (workspace root)
function M:setup_project_permissions(cwd)
	local claude_dir = cwd .. "/.claude"
	local settings_path = claude_dir .. "/settings.json"
	vim.fn.mkdir(claude_dir, "p")

	local existing = {}
	local f = io.open(settings_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		local ok, data = pcall(vim.json.decode, content)
		if ok and type(data) == "table" then
			existing = data
		end
	end

	existing.permissions = existing.permissions or {}
	existing.permissions.allow = existing.permissions.allow or {}

	-- Allow all built-in tool operations within this project.
	local needed = { "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)", "mcp__nvim-agent__*" }
	local allow = existing.permissions.allow
	for _, perm in ipairs(needed) do
		local found = false
		for _, v in ipairs(allow) do
			if v == perm then
				found = true
				break
			end
		end
		if not found then
			table.insert(allow, perm)
		end
	end

	local fw = io.open(settings_path, "w")
	if not fw then
		vim.notify("nvim-agent: failed to write " .. settings_path, vim.log.levels.ERROR)
		return
	end
	fw:write(vim.json.encode(existing))
	fw:close()
	vim.notify("nvim-agent: project permissions set (" .. settings_path .. ")", vim.log.levels.INFO)
end

--- Setup MCP server configuration in ~/.claude/settings.json.
--- Global entry defaults NVIM_AGENT_ACTIVE_DIR to session 1's active dir.
local function setup_mcp_server()
	-- Check if luajit is available
	vim.fn.system("which luajit 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		vim.notify("nvim-agent: luajit not found in PATH. MCP server will not be configured.", vim.log.levels.WARN)
		return
	end

	local settings_dir = vim.fn.expand("~/.claude")
	local settings_path = settings_dir .. "/settings.json"

	vim.fn.mkdir(settings_dir, "p")

	-- Read existing settings
	local existing = {}
	local f = io.open(settings_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, data = pcall(vim.json.decode, content)
			if ok and type(data) == "table" then
				existing = data
			end
		end
	end

	-- Get Neovim RPC address
	local nvim_address = vim.v.servername
	if not nvim_address or nvim_address == "" then
		vim.notify(
			"nvim-agent: Could not determine Neovim server address. MCP server will not be configured.",
			vim.log.levels.WARN
		)
		return
	end

	-- Get the path to the MCP server script (searches runtimepath so it works
	-- regardless of how the plugin is installed: lazy.nvim, packer, manual, etc.)
	local mcp_server_path = vim.api.nvim_get_runtime_file("lua/nvim-agent/mcp/server.lua", false)[1]
	if not mcp_server_path or not vim.loop.fs_stat(mcp_server_path) then
		vim.notify("nvim-agent: MCP server script not found on runtimepath (lua/nvim-agent/mcp/server.lua)", vim.log.levels.WARN)
		return
	end

	-- Default dirs point to the first (main) session of this process.
	-- Structure: sessions/<pid>/<name>/active/  and  sessions/<pid>/ephemeral.json
	local session_mod = require("nvim-agent.session")
	local process_dir = session_mod.get_process_dir()
	local session1_active = process_dir .. "/main/active"

	-- Check if MCP server already configured
	if existing.mcpServers and existing.mcpServers["nvim-agent"] then
		-- Update the address in case it changed; ensure both dir vars are set
		existing.mcpServers["nvim-agent"].env = existing.mcpServers["nvim-agent"].env or {}
		existing.mcpServers["nvim-agent"].env.NVIM_LISTEN_ADDRESS = nvim_address
		existing.mcpServers["nvim-agent"].env.NVIM_AGENT_ACTIVE_DIR = existing.mcpServers["nvim-agent"].env.NVIM_AGENT_ACTIVE_DIR
			or session1_active
		existing.mcpServers["nvim-agent"].env.NVIM_AGENT_PROCESS_DIR = existing.mcpServers["nvim-agent"].env.NVIM_AGENT_PROCESS_DIR
			or process_dir
	else
		-- Add new MCP server configuration
		existing.mcpServers = existing.mcpServers or {}
		existing.mcpServers["nvim-agent"] = {
			command = "luajit",
			args = { mcp_server_path },
			env = {
				NVIM_LISTEN_ADDRESS = nvim_address,
				NVIM_AGENT_ACTIVE_DIR = session1_active,
				NVIM_AGENT_PROCESS_DIR = process_dir,
			},
		}
	end

	local fw = io.open(settings_path, "w")
	if not fw then
		vim.notify("nvim-agent: failed to write " .. settings_path, vim.log.levels.ERROR)
		return
	end
	fw:write(vim.json.encode(existing))
	fw:close()

	vim.notify(string.format("nvim-agent: MCP server configured (address: %s)", nvim_address), vim.log.levels.INFO)
end

--- Add mcp__nvim-agent__* to permissions.allow in ~/.claude/settings.json
--- so Claude Code never prompts for permission before calling nvim-agent tools.
local function write_tool_permissions()
	local settings_dir = vim.fn.expand("~/.claude")
	local settings_path = settings_dir .. "/settings.json"

	vim.fn.mkdir(settings_dir, "p")

	local existing = {}
	local f = io.open(settings_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, data = pcall(vim.json.decode, content)
			if ok and type(data) == "table" then
				existing = data
			end
		end
	end

	local permission_entry = "mcp__nvim-agent__*"

	existing.permissions = existing.permissions or {}
	existing.permissions.allow = existing.permissions.allow or {}

	-- Check if already present
	for _, v in ipairs(existing.permissions.allow) do
		if v == permission_entry then
			return
		end
	end

	table.insert(existing.permissions.allow, permission_entry)

	local fw = io.open(settings_path, "w")
	if not fw then
		vim.notify("nvim-agent: failed to write " .. settings_path, vim.log.levels.ERROR)
		return
	end
	fw:write(vim.json.encode(existing))
	fw:close()
end

function M:setup()
	write_hook_script()
	write_claude_settings()
	write_claude_md()
	setup_mcp_server()
	write_tool_permissions()
end

function M:get_context_injection_config()
	return {
		hooks = {
			UserPromptSubmit = {
				{
					hooks = {
						{
							type = "command",
							command = hook_script_path(),
						},
					},
				},
			},
		},
	}
end

function M:on_enter(_)
	-- Terminal cursor position syncs automatically when entering terminal mode (i)
	-- No special handling needed in normal mode
end

function M:setup_buffer_keymaps(bufnr)
	-- <Esc><Esc> exits terminal mode to normal mode
	vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", {
		buffer = bufnr,
		desc = "Exit terminal mode",
	})
end

return M
