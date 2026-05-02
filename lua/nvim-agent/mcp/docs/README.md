# Neovim MCP Server

This is an MCP (Model Context Protocol) server that enables Claude Code to directly control a Neovim instance via its RPC interface. The server implements the MCP protocol over stdio and communicates with Neovim using shell commands.

## Architecture

```
Claude Code CLI
    ↓ (stdio: JSON-RPC 2.0)
MCP Server (Lua)
    ↓ (shell exec: nvim --server <address> --remote-expr)
Neovim Instance (RPC)
```

## Prerequisites

- **Neovim 0.10+** with RPC support enabled (the MCP server runs via `nvim -l`, using the LuaJIT bundled with Neovim)
- **Claude Code CLI** installed

## How It Works

1. When you start the nvim-agent adapter, it automatically configures the MCP server in `~/.claude/settings.json`
2. The configuration includes the `NVIM_AGENT_NVIM_ADDR` environment variable pointing to your Neovim instance's RPC socket. We deliberately do not use `NVIM_LISTEN_ADDRESS`, since `nvim -l` would otherwise try to bind to it.
3. When Claude Code starts, it launches the MCP server as a subprocess (`nvim -l server.lua`)
4. The server communicates with Claude Code via JSON-RPC 2.0 over stdin/stdout
5. The server communicates with Neovim by executing `nvim --server <address> --remote-expr` commands
6. All tool calls are gated by Claude Code's approval system

## Available Tools

### 1. list_buffers
Lists all open buffers with their metadata.

**Parameters:** None

**Returns:**
```json
[
  {
    "bufnr": 1,
    "name": "/path/to/file.lua",
    "modified": false,
    "buftype": ""
  }
]
```

### 2. get_buffer_content
Reads the complete content of a buffer.

**Parameters:**
- `bufnr` (number): The buffer number to read

**Returns:** The buffer content as plain text (newline-separated lines)

### 3. set_buffer_content
Replaces the entire content of a buffer.

**Parameters:**
- `bufnr` (number): The buffer number to write to
- `lines` (array): Array of strings, each representing a line

**Returns:** Success message

### 4. open_buffer
Opens a file in Neovim.

**Parameters:**
- `filepath` (string): Absolute or relative path to the file

**Returns:** The buffer number of the opened file

### 5. close_buffer
Closes a buffer by its number.

**Parameters:**
- `bufnr` (number): The buffer number to close

**Returns:** Success message

### 6. execute_command
Executes a Neovim ex command.

**Parameters:**
- `command` (string): The ex command to execute (without the leading ':')

**Examples:**
- `"w"` - Save the current buffer
- `"set number"` - Show line numbers
- `"vsplit"` - Create a vertical split

**Returns:** Success message

### 7. set_cursor
Moves the cursor to a specific position.

**Parameters:**
- `row` (number): Row number (1-indexed, line number)
- `col` (number): Column number (0-indexed, character position in line)

**Returns:** Success message

### 8. get_cursor
Gets the current cursor position.

**Parameters:** None

**Returns:**
```json
{
  "row": 10,
  "col": 5
}
```

## Manual Testing

You can test the MCP server manually before using it with Claude Code:

```bash
# Set the Neovim address (get this from :echo v:servername in Neovim)
export NVIM_AGENT_NVIM_ADDR=/tmp/nvim.sock

# Test initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | nvim -l server.lua

# Test tools/list
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | nvim -l server.lua

# Test list_buffers
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_buffers","arguments":{}}}' | nvim -l server.lua

# Test get_buffer_content (replace 1 with your buffer number)
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_buffer_content","arguments":{"bufnr":1}}}' | nvim -l server.lua

# Test open_buffer
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"open_buffer","arguments":{"filepath":"test.txt"}}}' | nvim -l server.lua

# Test execute_command
echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"execute_command","arguments":{"command":"set number"}}}' | nvim -l server.lua

# Test get_cursor
echo '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_cursor","arguments":{}}}' | nvim -l server.lua

# Test set_cursor
echo '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"set_cursor","arguments":{"row":10,"col":0}}}' | nvim -l server.lua
```

## Integration with Claude Code

Once the adapter's `setup()` function runs, the MCP server is automatically configured. You can verify by checking `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "nvim-agent": {
      "command": "/usr/bin/nvim",
      "args": ["-l", "/path/to/nvim-agent/lua/nvim-agent/mcp/server.lua"],
      "env": {
        "NVIM_AGENT_NVIM_ADDR": "/tmp/nvim.sock"
      }
    }
  }
}
```

(`command` is set dynamically to `vim.v.progpath` so the spawned `nvim` is the same binary the user is running.)

When you launch Claude Code from the nvim-agent terminal, it will automatically start the MCP server and make the tools available.

## Troubleshooting

### MCP server not connecting

1. Check that `NVIM_AGENT_NVIM_ADDR` is set in `~/.claude/settings.json` and matches your Neovim instance:
   ```vim
   :echo v:servername
   ```

2. Verify nvim is in your PATH (the MCP server is launched as `nvim -l server.lua`):
   ```bash
   which nvim
   ```

3. Test the MCP server manually (see Manual Testing section above)

4. Check Claude Code's logs for MCP-related errors:
   ```bash
   tail -f ~/.claude/logs/*
   ```

### "NVIM_AGENT_NVIM_ADDR not set" error

This means the environment variable is not being passed to the MCP server. Check that:

1. Your Neovim instance has a server name: `:echo v:servername`
2. The adapter's `setup()` function ran successfully
3. The `~/.claude/settings.json` file contains the correct `NVIM_AGENT_NVIM_ADDR` under `mcpServers["nvim-agent"].env`

### Commands fail with "nvim command failed"

This usually means Neovim is not responding on the RPC address. Check:

1. The Neovim instance is still running
2. The server address matches: `:echo v:servername` in Neovim
3. You have permission to access the socket file (if using Unix sockets)

### JSON decode errors

This usually indicates a bug in the Lua code that generates invalid JSON. Check:

1. The Lua code properly escapes special characters in strings
2. Test the specific tool call manually to see the raw output

## Security Notes

- All tool calls are gated by Claude Code's approval system
- The server only accepts commands from stdin (no network exposure)
- All shell commands use proper escaping to prevent injection attacks
- The server runs with your user's permissions (same as Neovim)
- No path traversal validation is needed (Neovim handles this)

## Performance

- Shell execution overhead: 10-50ms per call
- Large buffer reads: 50-200ms
- All operations are within interactive tolerance thresholds
- Acceptable for human-in-loop tool usage

## Files

- `server.lua` - Main MCP server (JSON-RPC 2.0 over stdio)
- `nvim_rpc.lua` - Neovim RPC wrapper using shell commands
- `tools.lua` - Tool definitions and handlers
- `filelock.lua` - Cross-process file locking (mkdir-based)
