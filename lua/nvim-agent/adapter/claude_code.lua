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

-- Permission profiles are built from a small set of named tool groups so that
-- changes to the MCP tool surface land in one place.
local TOOL_GROUPS = {
	read_builtins  = { "Read(*)", "Glob(*)", "Grep(*)" },
	write_builtins = { "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)" },
	mcp_read = {
		"mcp__nvim-agent__read_file",
		"mcp__nvim-agent__search_file",
		"mcp__nvim-agent__list_buffers",
		"mcp__nvim-agent__get_buffer_content",
		"mcp__nvim-agent__execute_command",
	},
	mcp_coord = {
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
}

local function profile(...)
	local allow = {}
	for _, group in ipairs({ ... }) do
		for _, entry in ipairs(group) do
			table.insert(allow, entry)
		end
	end
	return { allow = allow, deny = {} }
end

local PERMISSION_PROFILES = {
	-- Full access: can read, write, execute, and use all MCP tools.
	-- For: Senior SWEs, Junior SWEs
	["full"] = { allow = {
		"Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)",
		"mcp__nvim-agent__*",
	}, deny = {} },

	-- QA: full filesystem access via Claude built-ins, plus read-only MCP
	-- surface and coordination tools. (get_cursor is QA-specific.)
	["qa"] = profile(
		TOOL_GROUPS.write_builtins,
		TOOL_GROUPS.mcp_read,
		{ "mcp__nvim-agent__get_cursor" },
		TOOL_GROUPS.mcp_coord
	),

	-- Oversight: read-only access for stakeholders.
	-- For: Product Managers, CEOs, stakeholders
	["oversight"] = profile(TOOL_GROUPS.read_builtins, TOOL_GROUPS.mcp_read, TOOL_GROUPS.mcp_coord),

	-- Orchestrator: oversight + spawn_agent.
	-- For: RoboResources, resource managers
	["orchestrator"] = profile(
		TOOL_GROUPS.read_builtins,
		TOOL_GROUPS.mcp_read,
		TOOL_GROUPS.mcp_coord,
		{ "mcp__nvim-agent__spawn_agent" }
	),
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

	-- Compose the agent's system prompt: per-session system_prompt.md (if any)
	-- as the base, with agent_instruction_header always appended on top so the
	-- agent knows about the nvim-agent runtime contract.
	local prompt = require("nvim-agent.context").get_agent_preamble(read_system_prompt(active_dir))

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
				command = vim.v.progpath,
				args = { "-l", mcp_server_path },
				env = {
					NVIM_AGENT_NVIM_ADDR = nvim_address,
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
---
--- Sections are emitted in stable→volatile order so Anthropic's automatic
--- prefix caching can reuse the longest possible cached prefix between
--- prompts. Anything that is likely to be byte-identical across consecutive
--- prompts (role, project doc, flavor metadata) goes first; the most
--- volatile content (ephemeral editor state, refreshed on every BufEnter)
--- goes last.
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

# --- 0. Static header --------------------------------------------------------
echo "🚨 REMINDER: Use MCP tools for ALL file operations: read_file to read, edit_buffer to write, search_file to find code. DO NOT use built-in Read/Write/Edit tools."
echo ""
echo "=== NEOVIM EDITOR CONTEXT ==="

# --- 1. Identity & project context (most stable) ----------------------------
# role.md changes only when the user runs :NvimAgent role edit.
if [ -f "$ACTIVE_DIR/role.md" ]; then
    echo "--- role.md ---"
    cat "$ACTIVE_DIR/role.md"
    echo ""
fi
# PROJECT.md is the user's hand-edited project doc; rarely changes.
if [ -n "$CWD" ] && [ -f "$CWD/PROJECT.md" ]; then
    echo "--- PROJECT.md ---"
    cat "$CWD/PROJECT.md"
    echo ""
fi

# --- 2. Session preset (stable per session) ---------------------------------
# .flavor_meta.json: changes only when the user switches flavor/checkpoint.
# persistent_dirs.json + user_notes.md: hand-edited, occasional changes.
for f in .flavor_meta.json persistent_dirs.json user_notes.md; do
    if [ -f "$ACTIVE_DIR/$f" ]; then
        echo "--- $f ---"
        cat "$ACTIVE_DIR/$f"
        echo ""
    fi
done

# --- 3. Persistent agent state (occasional appends) -------------------------
# All project-level communication lives in $CWD/.nvim-agent/
if [ -n "$CWD" ] && [ -n "$SESSION_NAME" ]; then
    PROJ_DIR="$CWD/.nvim-agent"

    # agent_history.md grows when the agent calls log_work — between calls it's stable.
    PROJ_HIST="$PROJ_DIR/history/$SESSION_NAME.md"
    if [ -s "$PROJ_HIST" ]; then
        echo "--- agent_history.md (last 40 lines) ---"
        tail -40 "$PROJ_HIST"
        echo ""
    fi
fi

# --- 4. External captures (occasional) --------------------------------------
# Tmux pane captures only update when the user explicitly captures a pane.
if [ -n "$PROCESS_DIR" ] && [ -f "$PROCESS_DIR/tmux_captures.json" ]; then
    echo "--- tmux_captures.json ---"
    cat "$PROCESS_DIR/tmux_captures.json"
    echo ""
fi

# --- 5. Multi-agent state (volatile when peers are active) ------------------
if [ -n "$CWD" ] && [ -n "$SESSION_NAME" ]; then
    PROJ_DIR="$CWD/.nvim-agent"

    # Status and role of all peer agents (from .nvim-agent/status/*.json).
    # Each peer rewrites their status file when they call update_status.
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

    # Pending messages addressed to this agent — appended by peers between prompts.
    MSG_FILE="$PROJ_DIR/messages/$SESSION_NAME.md"
    if [ -s "$MSG_FILE" ]; then
        echo "--- messages_for_you.md ---"
        cat "$MSG_FILE"
        echo "(Call the read_messages MCP tool after processing to clear these)"
        echo ""
    fi
fi

# --- 6. Editor state (most volatile — kept last to maximize prefix cache) ---
# ephemeral.json is rewritten on every BufEnter of any agent buffer in this
# Neovim process, so it's the section most likely to differ between prompts.
if [ -n "$PROCESS_DIR" ] && [ -f "$PROCESS_DIR/ephemeral.json" ]; then
    echo "--- ephemeral.json ---"
    cat "$PROCESS_DIR/ephemeral.json"
    echo ""
fi

echo "=== END NEOVIM CONTEXT ==="
]]
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

--- Strip legacy ~/.claude/CLAUDE.md block + global mcpServers entry written
--- by older versions of nvim-agent. Idempotent. We deliberately leave the
--- UserPromptSubmit hook entry alone in case the user has other hooks of
--- their own; the hook script self-gates on $NVIM_AGENT_ACTIVE_DIR.
local function cleanup_legacy_global_config()
	local claude_md_path = vim.fn.expand("~/.claude/CLAUDE.md")
	local f = io.open(claude_md_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		local marker_start = "<!-- nvim-agent:start -->"
		local marker_end = "<!-- nvim-agent:end -->"
		if content and content:find(marker_start, 1, true) then
			local pattern = vim.pesc(marker_start) .. ".-" .. vim.pesc(marker_end) .. "\n?"
			local cleaned = content:gsub(pattern, "")
			cleaned = cleaned:gsub("\n\n\n+", "\n\n")
			local fw = io.open(claude_md_path, "w")
			if fw then
				fw:write(cleaned)
				fw:close()
			end
		end
	end

	local settings_path = vim.fn.expand("~/.claude/settings.json")
	local sf = io.open(settings_path, "r")
	if sf then
		local raw = sf:read("*a")
		sf:close()
		local ok, settings = pcall(vim.json.decode, raw or "")
		if ok and type(settings) == "table" and settings.mcpServers and settings.mcpServers["nvim-agent"] then
			settings.mcpServers["nvim-agent"] = nil
			local sw = io.open(settings_path, "w")
			if sw then
				sw:write(vim.json.encode(settings))
				sw:close()
			end
		end
	end
end

function M:setup()
	-- Write the hook script that the per-session mcp-settings.json points at.
	write_hook_script()

	-- One-time migration: prior versions wrote a marker-delimited block into
	-- ~/.claude/CLAUDE.md and a global nvim-agent mcpServers entry into
	-- ~/.claude/settings.json. Both leaked operational instructions to plain
	-- claude sessions launched outside nvim-agent. We now keep all of that
	-- per-session via --system-prompt and --mcp-config, so strip any legacy
	-- copies left over from previous installs.
	cleanup_legacy_global_config()
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
