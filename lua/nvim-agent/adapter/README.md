# nvim-agent Adapter Interface

This document describes the adapter interface for integrating different AI coding assistants with nvim-agent. Adapters provide a bridge between the nvim-agent terminal and the external AI tool, handling setup, configuration, and context injection.

## Overview

An adapter is a Lua module that defines how to launch and interact with a specific AI coding assistant. The adapter system is designed to be flexible and extensible, allowing you to integrate any command-line AI tool.

nvim-agent supports multiple simultaneous sessions. Each session has:
- A unique compound ID (e.g. `485293847_1`)
- Its own directory at `~/.nvim-agent/sessions/<id>/`
- Its own active context dir at `~/.nvim-agent/sessions/<id>/active/`
- Its own per-session MCP settings at `~/.nvim-agent/sessions/<id>/mcp-settings.json`
- Its own terminal buffer named `[Agent-<n>: <flavor>]`
- Its own Claude Code process launched with `NVIM_AGENT_ACTIVE_DIR` pointing to its active dir

## Creating an Adapter

To create a new adapter, create a Lua file that returns a table inheriting from the base adapter:

```lua
local adapter_base = require("nvim-agent.adapter")
local M = adapter_base.new()

-- Implement required and optional methods here

return M
```

## Required Methods

### `get_cmd(session)`

Returns the command to launch the AI assistant as an array of strings. Receives the full session object so the command can be tailored to that session's active dir and MCP config.

```lua
function M:get_cmd(session)
    -- session.active_dir  — path to this session's context files
    -- session.dir         — path to this session's root dir (for mcp-settings.json)
    -- session.id          — compound string ID
    -- session.instance_num — user-visible session number
    return { "command", "arg1", "arg2" }
end
```

**Example (claude_code.lua):**
```lua
function M:get_cmd(session)
    local active_dir = session.active_dir
    local prompt_path = active_dir .. "/system_prompt.md"
    local mcp_config = session.dir .. "/mcp-settings.json"

    if vim.fn.filereadable(mcp_config) == 1 then
        return { "claude", "--system-prompt", prompt_path, "--mcp-config", mcp_config }
    else
        return { "claude", "--system-prompt", prompt_path }
    end
end
```

## Optional Methods

### `setup()`

Called once during adapter initialization (at Neovim startup, from `M:setup()` in `init.lua`). Use this for global one-time configuration:
- Write the hook script to `~/.nvim-agent/hooks/`
- Write to `~/.claude/CLAUDE.md`
- Add the hook entry to `~/.claude/settings.json`
- Add the global MCP server entry to `~/.claude/settings.json`
- Add tool permissions

```lua
function M:setup()
    write_hook_script()
    write_claude_settings()
    write_claude_md()
    setup_mcp_server()
    write_tool_permissions()
end
```

### `setup_session_mcp(session)`

Called by `terminal.lua` before launching each new session's terminal job. Use this to write a per-session MCP settings file that includes:
- The MCP server command with `NVIM_AGENT_ACTIVE_DIR` set to `session.active_dir`
- The `UserPromptSubmit` hook pointing to the hook script
- Tool permissions

```lua
function M:setup_session_mcp(session)
    local settings = {
        mcpServers = {
            ["nvim-agent"] = {
                command = "luajit",
                args = { mcp_server_path },
                env = {
                    NVIM_LISTEN_ADDRESS = vim.v.servername,
                    NVIM_AGENT_ACTIVE_DIR = session.active_dir,
                },
            },
        },
        hooks = {
            UserPromptSubmit = {
                { hooks = { { type = "command", command = hook_script_path() } } },
            },
        },
        permissions = { allow = { "mcp__nvim-agent__*" } },
    }
    local path = session.dir .. "/mcp-settings.json"
    -- write settings to path
end
```

Claude is launched with `--mcp-config session.dir/mcp-settings.json`, so each session's MCP server inherits the correct `NVIM_AGENT_ACTIVE_DIR` automatically.

### `on_enter(bufnr)`

Called every time the user enters an agent terminal buffer (via the `BufEnter` autocmd). Use this to sync state or update the UI.

```lua
function M:on_enter(bufnr)
    -- no-op by default
end
```

### `setup_buffer_keymaps(bufnr)`

Called after a new terminal buffer is created. Use this to add buffer-local keymaps.

```lua
function M:setup_buffer_keymaps(bufnr)
    vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", {
        buffer = bufnr,
        desc = "Exit terminal mode",
    })
end
```

### `get_context_injection_config()`

Returns configuration for context injection hooks. Returns `nil` in the base implementation.

```lua
function M:get_context_injection_config()
    return {
        hooks = {
            UserPromptSubmit = {
                { hooks = { { type = "command", command = "/path/to/hook.sh" } } },
            },
        },
    }
end
```

## Context Injection Architecture

Each session's context is injected via a `UserPromptSubmit` hook registered in the session's `mcp-settings.json`. The hook script reads from `$NVIM_AGENT_ACTIVE_DIR`, which is set in the terminal job's environment by `terminal.lua`:

```lua
sess.jobid = vim.fn.termopen(cmd, {
    env = { NVIM_AGENT_ACTIVE_DIR = sess.active_dir },
    ...
})
```

The MCP server subprocess inherits this env var from the Claude Code process, so it automatically serves the correct session's files.

### Hook Script Pattern

```bash
#!/usr/bin/env bash
ACTIVE_DIR="${NVIM_AGENT_ACTIVE_DIR}"
if [ -z "$ACTIVE_DIR" ]; then
    exit 0
fi

echo "=== NEOVIM EDITOR CONTEXT ==="
for f in .flavor_meta.json user_notes.md ephemeral.json persistent_dirs.json; do
    if [ -f "$ACTIVE_DIR/$f" ]; then
        echo "--- $f ---"
        cat "$ACTIVE_DIR/$f"
        echo ""
    fi
done
echo "=== END NEOVIM CONTEXT ==="
```

Context files injected per session:
- `.flavor_meta.json` — active flavor and checkpoint name (injected first)
- `user_notes.md` — user preferences and behavioral constraints
- `ephemeral.json` — current editor state (buffers, cursor, diagnostics, git)
- `persistent_dirs.json` — bookmarked code paths

## Reference Implementation: claude_code.lua

### `get_cmd(session)`
Reads `system_prompt.md` from `session.active_dir` and passes it via `--system-prompt`. Points `--mcp-config` at the per-session `mcp-settings.json`.

### `setup_session_mcp(session)`
Writes `session.dir/mcp-settings.json` with:
- The nvim-agent MCP server (`luajit mcp/server.lua`) with `NVIM_LISTEN_ADDRESS` and `NVIM_AGENT_ACTIVE_DIR` set to `session.active_dir`
- The `UserPromptSubmit` hook pointing to `~/.nvim-agent/hooks/claude_code_prompt.sh`
- `permissions.allow = ["mcp__nvim-agent__*"]`

### `setup()` (global, runs once)
1. Writes the hook script to `~/.nvim-agent/hooks/claude_code_prompt.sh`
2. Adds the `UserPromptSubmit` hook to `~/.claude/settings.json`
3. Writes the nvim-agent instruction block to `~/.claude/CLAUDE.md`
4. Adds the global MCP server entry to `~/.claude/settings.json` (with `NVIM_AGENT_ACTIVE_DIR` defaulting to session 1's active dir)
5. Adds `mcp__nvim-agent__*` to `permissions.allow`

### Setup Function
```lua
function M:setup()
    write_hook_script()      -- ~/.nvim-agent/hooks/claude_code_prompt.sh
    write_claude_settings()  -- global hook in ~/.claude/settings.json
    write_claude_md()        -- instruction block in ~/.claude/CLAUDE.md
    setup_mcp_server()       -- global MCP entry in ~/.claude/settings.json
    write_tool_permissions() -- permissions.allow in ~/.claude/settings.json
end
```

## Best Practices

### 1. Check Prerequisites
Always check that required tools are available before setting them up:

```lua
vim.fn.system("which luajit 2>/dev/null")
if vim.v.shell_error ~= 0 then
    vim.notify("luajit not found in PATH", vim.log.levels.WARN)
    return
end
```

### 2. Idempotent Global Setup
Make `setup()` idempotent — it can run on every Neovim startup:

```lua
if not (existing.hooks and existing.hooks.UserPromptSubmit) then
    existing.hooks = existing.hooks or {}
    existing.hooks.UserPromptSubmit = { ... }
end
```

### 3. Per-Session MCP Is Always Fresh
`setup_session_mcp()` is called fresh for every new session, so it always has the correct `NVIM_AGENT_ACTIVE_DIR` and current `NVIM_LISTEN_ADDRESS`. No idempotency check needed.

### 4. Error Handling
Provide helpful error messages when things go wrong:

```lua
local f = io.open(path, "w")
if not f then
    vim.notify("nvim-agent: failed to write " .. path, vim.log.levels.ERROR)
    return
end
```

### 5. Nil-guard the session parameter
Always guard against a nil session in `get_cmd()`:

```lua
function M:get_cmd(session)
    if not session then
        vim.notify("nvim-agent: get_cmd called without a session", vim.log.levels.ERROR)
        return { "claude" }
    end
    -- ...
end
```

## Testing Your Adapter

1. **Basic Launch**: Open a new session with your adapter active
   ```
   :NvimAgent session new
   ```

2. **Setup Verification**: Check that configuration files were created
   ```bash
   cat ~/.nvim-agent/sessions/<id>/mcp-settings.json
   cat ~/.nvim-agent/hooks/claude_code_prompt.sh
   ```

3. **Context Injection**: Verify the hook runs and injects context
   - Switch to the agent terminal buffer (triggers ephemeral refresh)
   - Send any prompt and confirm context files are prepended

4. **MCP Tools**: Verify tools are available in the session
   - Ask the AI to list available MCP tools
   - Confirm `NVIM_AGENT_ACTIVE_DIR` points to the right session dir

## File Structure

```
nvim-agent/
├── adapter/
│   ├── init.lua           # Base adapter class
│   ├── claude_code.lua    # Reference implementation
│   └── README.md          # This file
├── session.lua            # Session registry (create/get/list/close)
├── terminal.lua           # Terminal management (calls get_cmd, setup_session_mcp)
├── mcp/                   # MCP server implementation
│   ├── server.lua
│   ├── nvim_rpc.lua
│   ├── tools.lua          # reads NVIM_AGENT_ACTIVE_DIR from env
│   └── dkjson.lua
└── ...
```

## Summary

To create a new adapter:

1. Create a new Lua file in `nvim-agent/adapter/`
2. Inherit from the base adapter via `adapter_base.new()`
3. Implement `get_cmd(session)` — receives the full session object
4. Implement `setup_session_mcp(session)` — writes per-session config with `NVIM_AGENT_ACTIVE_DIR`
5. Optionally implement `setup()` for global one-time configuration
6. Optionally implement `setup_buffer_keymaps(bufnr)` and `on_enter(bufnr)`

For a complete working example, see `claude_code.lua`.
