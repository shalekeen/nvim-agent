-- Adapter skeleton for a generic coding-agent CLI.
--
-- To create a new adapter:
--   1. cp TEMPLATE.lua <your_cli>.lua
--   2. Rename M's internals, fill in CLI specifics
--   3. Register in adapter/init.lua's `builtin_adapters` table
--   4. Walk the porting checklist in README.md
--
-- Sections marked  REQUIRED  must be filled in. Sections marked  OPTIONAL
-- can be deleted if your CLI doesn't have the corresponding feature.
--
-- This skeleton assumes a CLI that:
--   - Reads its system prompt from a CLI flag (via a temp file or argv string)
--   - Supports MCP servers (delete §3 if not)
--   - Has a per-prompt hook mechanism (delete §4 if not)
--   - Has a JSON settings file (delete §2 if not)

local adapter_base = require("nvim-agent.adapter")
local config = require("nvim-agent.config")
local context = require("nvim-agent.context")

local M = adapter_base.new()

------------------------------------------------------------------------
-- Local helpers
------------------------------------------------------------------------

-- Where this adapter's pre-prompt hook script lives. The script runs each
-- time the user submits a prompt and cat's the relevant context files into
-- the CLI's stdin (or wherever the CLI reads pre-prompt content from).
local function hook_script_path()
	local base_dir = config.get().base_dir or vim.fn.expand("~/.nvim-agent")
	return base_dir .. "/hooks/your_cli_prompt.sh"
end

-- Where the MCP server lives on disk. Used by setup_session_mcp.
local function mcp_server_path()
	-- runtime_file resolves a path inside the plugin tree without needing the
	-- user's plugin manager to expose it. See config.lua for the impl.
	return config.runtime_file("mcp/server.lua")
end

------------------------------------------------------------------------
-- §1. get_cmd(session)   ── REQUIRED
--
-- Build the argv array used by termopen. The harness calls this every time
-- a session's terminal is opened (or re-opened after toggling).
--
-- Key invariants:
--   - Nil-guard session — the harness occasionally calls with nil during
--     setup probes. Return a safe argv that won't crash if used.
--   - Always compose the system prompt via context.compose_system_prompt
--     so the runtime preamble (telling the agent how to interpret editor
--     context) is included. Don't read system_prompt.md directly.
------------------------------------------------------------------------

function M:get_cmd(session)
	if not session then
		vim.notify("nvim-agent: get_cmd called without a session", vim.log.levels.ERROR)
		return { "your-cli" }
	end

	-- Three-layer composition: runtime preamble + system_prompt.md + agent_prompt.md.
	local prompt = context.compose_system_prompt(session.active_dir)

	-- Strategy A — pass the prompt as a CLI argument.
	-- Use this if your CLI accepts a (potentially very long) string flag.
	local cmd = { "your-cli", "--system-prompt", prompt }

	-- Strategy B — write the prompt to a file and pass the path.
	-- Use this if your CLI has argv-length limits or only accepts a file path.
	-- local prompt_path = session.dir .. "/system-prompt.txt"
	-- vim.fn.writefile(vim.split(prompt, "\n"), prompt_path)
	-- local cmd = { "your-cli", "--system-prompt-file", prompt_path }

	-- If your CLI supports MCP, point it at the per-session settings file.
	-- (See §3 — setup_session_mcp writes this file.)
	local mcp_config = session.dir .. "/mcp-settings.json"
	if vim.fn.filereadable(mcp_config) == 1 then
		table.insert(cmd, "--mcp-config")
		table.insert(cmd, mcp_config)
	end

	return cmd
end

------------------------------------------------------------------------
-- §2. setup_session_mcp(session)   ── OPTIONAL (recommended if CLI has MCP)
--
-- Write per-session config the CLI consumes at launch. Called fresh for
-- every new session, so no idempotency check needed.
--
-- The MCP server lets the agent reach back into Neovim — read/write
-- buffers, search files, exchange messages with peer agents, etc. If
-- your CLI doesn't support MCP, delete this function entirely.
------------------------------------------------------------------------

function M:setup_session_mcp(session)
	local nvim_address = vim.v.servername
	if not nvim_address or nvim_address == "" then
		vim.notify(
			"nvim-agent: could not determine Neovim socket. Per-session MCP not configured.",
			vim.log.levels.WARN
		)
		return
	end

	local settings = {
		mcpServers = {
			["nvim-agent"] = {
				-- Spawn the MCP server via the running Neovim's bundled LuaJIT
				-- so users don't need an external luajit binary.
				command = vim.v.progpath,
				args = { "-l", mcp_server_path() },
				env = {
					-- NOT NVIM_LISTEN_ADDRESS — `nvim -l` intercepts that var
					-- and tries to bind to it.
					NVIM_AGENT_NVIM_ADDR = nvim_address,
					NVIM_AGENT_ACTIVE_DIR = session.active_dir,
					NVIM_AGENT_PROCESS_DIR = session.process_dir,
					NVIM_AGENT_CWD = vim.fn.getcwd(),
				},
			},
		},
		-- Pre-prompt hook: see §4. If your CLI uses a different hook shape
		-- (or doesn't have hooks), adjust or delete this block.
		hooks = {
			UserPromptSubmit = {
				{ hooks = { { type = "command", command = hook_script_path() } } },
			},
		},
		-- Pre-allow MCP tools so the agent isn't prompted on each call.
		permissions = { allow = { "mcp__nvim-agent__*" } },
	}

	local path = session.dir .. "/mcp-settings.json"
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		vim.notify("nvim-agent: failed to write " .. path, vim.log.levels.ERROR)
		return
	end
	f:write(vim.json.encode(settings))
	f:close()
end

------------------------------------------------------------------------
-- §3. The pre-prompt hook script   ── OPTIONAL
--
-- The hook script runs in the CLI's pre-prompt lifecycle (if it has one)
-- and writes the current editor context to stdout. The CLI prepends that
-- to the user's next prompt.
--
-- Order from most stable to most volatile to maximize prefix-cache reuse
-- (Anthropic's prompt cache reuses the longest identical prefix between
-- calls — keep volatile content at the end).
--
-- Delete this function and the corresponding `hooks` field above if your
-- CLI has no pre-prompt lifecycle.
------------------------------------------------------------------------

local function hook_script_content()
	return [[#!/usr/bin/env bash
ACTIVE_DIR="${NVIM_AGENT_ACTIVE_DIR}"
PROCESS_DIR="${NVIM_AGENT_PROCESS_DIR}"
CWD="${NVIM_AGENT_CWD}"
if [ -z "$ACTIVE_DIR" ]; then
    exit 0
fi

SESSION_NAME=$(basename "$(dirname "$ACTIVE_DIR")")

echo "=== NEOVIM EDITOR CONTEXT ==="

# Stable: role + project doc
[ -f "$ACTIVE_DIR/role.md" ] && { echo "--- role.md ---"; cat "$ACTIVE_DIR/role.md"; echo; }
[ -n "$CWD" ] && [ -f "$CWD/PROJECT.md" ] && { echo "--- PROJECT.md ---"; cat "$CWD/PROJECT.md"; echo; }

# Semi-stable: flavor + pinned dirs + user notes
for f in .flavor_meta.json persistent_dirs.json user_notes.md; do
    [ -f "$ACTIVE_DIR/$f" ] && { echo "--- $f ---"; cat "$ACTIVE_DIR/$f"; echo; }
done

# Project-scoped (workspace mode): peer statuses + message mailbox
if [ -n "$CWD" ] && [ -n "$SESSION_NAME" ]; then
    PROJ_DIR="$CWD/.nvim-agent"
    MSG_FILE="$PROJ_DIR/messages/$SESSION_NAME.md"
    [ -s "$MSG_FILE" ] && { echo "--- messages_for_you.md ---"; cat "$MSG_FILE"; echo; }
fi

# Volatile: current editor state. Kept last so the prefix above stays cacheable.
[ -n "$PROCESS_DIR" ] && [ -f "$PROCESS_DIR/ephemeral.json" ] && {
    echo "--- ephemeral.json ---"
    cat "$PROCESS_DIR/ephemeral.json"
    echo
}

echo "=== END NEOVIM CONTEXT ==="
]]
end

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

------------------------------------------------------------------------
-- §4. setup()   ── OPTIONAL
--
-- Runs once at plugin startup. Use it to install global config that
-- doesn't change per-session: write the hook script, register the MCP
-- server in the CLI's global settings, install CLI-side documentation.
--
-- MUST be idempotent — runs on every Neovim startup. Don't append; merge.
------------------------------------------------------------------------

function M:setup()
	-- 1. CLI present?
	vim.fn.system("which your-cli 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		vim.notify("nvim-agent: 'your-cli' not found in PATH", vim.log.levels.WARN)
		return
	end

	-- 2. Hook script (idempotent — same content every time)
	write_hook_script()

	-- 3. CLI global settings — merge our entries without clobbering others.
	-- The exact path and shape depends on your CLI. Sketch only:
	--
	-- local settings_path = vim.fn.expand("~/.your-cli/settings.json")
	-- local existing = read_json_or_empty(settings_path)
	-- existing.mcpServers = existing.mcpServers or {}
	-- existing.mcpServers["nvim-agent"] = { ... }  -- always overwrite, idempotent
	-- existing.hooks = existing.hooks or {}
	-- ensure_hook_entry(existing.hooks, hook_script_path())
	-- write_json(settings_path, existing)
end

------------------------------------------------------------------------
-- §5. setup_project_permissions(cwd)   ── OPTIONAL
--
-- Called when a workspace is launched. Use this to write project-scoped
-- CLI settings (e.g. <cwd>/.your-cli/settings.json) so agents inside the
-- project don't get permission-prompted for every file/bash operation.
--
-- Delete if your CLI has no project-scoped settings.
------------------------------------------------------------------------

function M:setup_project_permissions(cwd)
	-- Example shape:
	-- local path = cwd .. "/.your-cli/settings.json"
	-- vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	-- write_json(path, { permissions = { allow = { ... } } })
end

------------------------------------------------------------------------
-- §6. setup_buffer_keymaps(bufnr)   ── OPTIONAL
--
-- Called once per session terminal buffer. Add buffer-local keymaps.
------------------------------------------------------------------------

function M:setup_buffer_keymaps(bufnr)
	-- Exit terminal-mode with <Esc><Esc> (most agent CLIs eat single <Esc>):
	vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", {
		buffer = bufnr,
		desc = "Exit terminal mode",
	})
end

------------------------------------------------------------------------
-- §7. on_enter(bufnr)   ── OPTIONAL
--
-- Called on every BufEnter of an agent terminal. The harness already
-- refreshes ephemeral.json here — only override if you need to do
-- something CLI-specific (e.g. resize the terminal to match window).
------------------------------------------------------------------------

-- function M:on_enter(bufnr)
--     -- No-op by default; the harness's BufEnter handler refreshes ephemeral.json.
-- end

return M
