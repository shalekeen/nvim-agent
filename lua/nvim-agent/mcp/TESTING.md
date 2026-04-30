# Integration Testing Guide

This guide walks you through testing the MCP server integration with Claude Code.

## Prerequisites Check

Before testing, verify you have all required components:

```bash
# Check Neovim version (need 0.10+; the MCP server runs via `nvim -l`)
nvim --version | head -1

# Check Claude Code is installed
which claude

# Check all MCP Lua files are present
ls -la lua/nvim-agent/mcp/*.lua
```

## Step 1: Verify Neovim RPC is Working

1. Start Neovim in one terminal:
   ```bash
   nvim
   ```

2. Get the server address (in Neovim):
   ```vim
   :echo v:servername
   ```

   You should see something like `/tmp/nvim.1234.0` or similar.

3. In another terminal, test RPC connectivity:
   ```bash
   export NVIM_AGENT_NVIM_ADDR="<address from step 2>"
   nvim --server "$NVIM_AGENT_NVIM_ADDR" --remote-expr "1+1"
   ```

   This should output `2` if RPC is working.

## Step 2: Test MCP Server Standalone

With `NVIM_AGENT_NVIM_ADDR` exported from Step 1:

```bash
cd lua/nvim-agent/mcp

# Test initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | nvim -l server.lua

# Test tools/list
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | nvim -l server.lua

# Test list_buffers (should show buffers open in your Neovim instance)
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_buffers","arguments":{}}}' | nvim -l server.lua
```

Expected results:
- `initialize` returns protocol version and server info
- `tools/list` returns array of 8 tools
- `list_buffers` returns JSON array of open buffers

## Step 3: Test Adapter Setup

1. In Neovim, run the adapter setup:
   ```vim
   :lua require("nvim-agent.adapter.claude_code"):setup()
   ```

2. Check that files were created:
   ```bash
   # Check hook script was created
   ls -la ~/.nvim-agent/hooks/claude_code_prompt.sh

   # Check settings were updated
   cat ~/.claude/settings.json | jq '.hooks.UserPromptSubmit'
   cat ~/.claude/settings.json | jq '.mcpServers."nvim-agent"'

   # Check CLAUDE.md was updated
   grep -A 20 "nvim-agent:start" ~/.claude/CLAUDE.md
   ```

Expected results:
- Hook script exists and is executable
- settings.json contains UserPromptSubmit hook pointing to the script
- settings.json contains nvim-agent MCP server config with correct `NVIM_AGENT_NVIM_ADDR`
- CLAUDE.md contains nvim-agent block with MCP documentation

## Step 4: Test in Claude Code

1. In Neovim, open the nvim-agent terminal:
   ```vim
   :lua require("nvim-agent.terminal").toggle("claude_code")
   ```

2. Wait for Claude Code to start. You should see the terminal open with the Claude prompt.

3. Look for MCP server indicators. Claude Code shows connected MCP servers in the UI.

4. Test basic context injection by asking:
   ```
   What files are currently open in my editor?
   ```

   Claude should respond with information from ephemeral.json.

5. Test MCP tools by asking:
   ```
   Use the list_buffers tool to show me all open buffers
   ```

   Claude should use the MCP tool and show the actual buffer list.

6. Test buffer manipulation:
   ```
   Use get_buffer_content to show me the contents of buffer 1
   ```

7. Test cursor control:
   ```
   Use get_cursor to tell me where my cursor is
   ```

8. Test command execution:
   ```
   Use execute_command to run "set number"
   ```

## Step 5: Test Dynamic Address Updates

This tests that the MCP server address updates when Neovim restarts:

1. Close Neovim
2. Start Neovim again (server address will likely be different)
3. Run adapter setup again:
   ```vim
   :lua require("nvim-agent.adapter.claude_code"):setup()
   ```
4. Check that settings.json was updated:
   ```bash
   cat ~/.claude/settings.json | jq '.mcpServers."nvim-agent".env.NVIM_AGENT_NVIM_ADDR'
   ```

   Should show the new address matching `:echo v:servername`

## Expected Behavior

### Successful Integration Signs:
- ✅ MCP server starts without errors
- ✅ Claude Code shows "nvim-agent" in connected servers
- ✅ Context files are injected before each prompt
- ✅ All 8 tools are available and functional
- ✅ Tools can read and modify Neovim state
- ✅ Commands execute without errors

### Common Issues and Fixes:

**"NVIM_AGENT_NVIM_ADDR not set"**
- Cause: Environment variable not passed to MCP server
- Fix: Re-run adapter setup, check settings.json

**"nvim command failed"**
- Cause: Neovim not responding on RPC address
- Fix: Verify Neovim is running, check v:servername matches

**"MCP server not connecting"**
- Cause: nvim binary not on PATH, or server.lua missing from runtimepath
- Fix: Verify `which nvim` resolves; confirm `lua/nvim-agent/mcp/server.lua` exists in your install

**"JSON decode error"**
- Cause: Bug in Lua code generating invalid JSON
- Fix: Test tool standalone, check stderr output

## Debugging Tips

### View MCP Server Logs

The MCP server writes to stderr, which Claude Code captures. To see logs:

```bash
# Check Claude Code logs directory
ls ~/.claude/logs/

# View recent MCP server output
grep -r "MCP Server" ~/.claude/logs/
```

### Test Individual Tools

Test each tool in isolation to identify issues:

```bash
export NVIM_AGENT_NVIM_ADDR=$(nvim --server /tmp/test.sock --remote-expr 'v:servername')

# Test each tool
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_buffers","arguments":{}}}' | nvim -l server.lua

echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_cursor","arguments":{}}}' | nvim -l server.lua

# etc.
```

### Verbose Mode

Add debug output to server.lua for troubleshooting:

```lua
-- Add after line processing in main()
io.stderr:write(string.format("Received: %s\n", line))
io.stderr:flush()
```

## Success Criteria Checklist

- [ ] All Lua files have correct syntax
- [ ] MCP server responds to initialize
- [ ] All 8 tools are listed
- [ ] Adapter setup creates all required files
- [ ] settings.json contains correct configuration
- [ ] Claude Code connects to MCP server
- [ ] list_buffers returns actual buffer list
- [ ] get_buffer_content returns file contents
- [ ] set_buffer_content modifies buffer
- [ ] execute_command runs Neovim commands
- [ ] cursor tools work correctly
- [ ] Context injection works (ephemeral.json visible)
- [ ] Dynamic address updates work

## Performance Expectations

Typical response times:
- Tool call latency: 10-50ms
- Buffer read (small file): 20-100ms
- Buffer read (large file): 100-500ms
- Command execution: 10-30ms
- Context injection: 5-20ms

All operations should feel instantaneous for human interaction.
