# Real-Time Editing Guide

This guide explains how to make Claude Code's edits appear in real-time in your Neovim editor.

## How It Works

### The Problem with Built-in Tools

Claude Code has built-in tools (`Read`, `Write`, `Edit`) that work directly on the filesystem:
- They modify files on disk
- Neovim doesn't automatically reload changed files
- You don't see edits until you manually reload (`:e`)
- The agent can't control which files are visible

### The Solution: MCP Tools

Our MCP server provides tools that directly control Neovim:
- **edit_buffer** - Opens files, applies changes, focuses the window, and saves
- All operations happen inside Neovim
- Changes are immediately visible
- The agent controls which buffers are open and focused

## Architecture

```
User asks Claude to edit a file
    ↓
Claude Code uses edit_buffer MCP tool
    ↓
MCP Server sends command to Neovim via RPC
    ↓
Neovim opens/switches to the file
    ↓
Neovim applies the changes
    ↓
Neovim saves the file
    ↓
Neovim focuses on the buffer
    ↓
User sees the changes in real-time!
```

## The edit_buffer Tool

This is the **primary tool** for all file editing. It combines multiple operations:

```javascript
{
  "name": "edit_buffer",
  "arguments": {
    "filepath": "path/to/file.lua",
    "lines": ["line 1", "line 2", "..."],
    "save": true,           // optional, default: true
    "cursor_line": 10       // optional, positions cursor
  }
}
```

**What it does:**
1. Opens the file (or switches to it if already open)
2. Replaces content with new lines
3. Saves the file (unless save=false)
4. Positions cursor (if cursor_line specified)
5. Focuses the buffer window

**Result:** The user sees the file appear (if not already visible) with the new content applied instantly.

## Instructing Claude to Use MCP Tools

The adapter automatically adds instructions to `~/.claude/CLAUDE.md`:

```markdown
### IMPORTANT: Prefer MCP Tools for File Operations

When editing files, you MUST use the `edit_buffer` MCP tool
instead of the built-in Read/Write/Edit tools.
```

This instructs Claude Code to use the MCP tools instead of filesystem tools.

## Workflow Examples

### Example 1: Simple File Edit

**User:** "Update the greeting in hello.lua to say 'Hello World'"

**Claude uses:**
```json
{
  "tool": "edit_buffer",
  "arguments": {
    "filepath": "hello.lua",
    "lines": [
      "local function greet()",
      "  print('Hello World')",
      "end",
      "",
      "greet()"
    ],
    "save": true
  }
}
```

**User sees:**
- `hello.lua` opens in a new buffer (or switches to existing)
- Content updates instantly
- File is saved
- Buffer has focus

### Example 2: Multi-File Edit with Cursor Positioning

**User:** "Fix the bug in both main.lua and utils.lua"

**Claude uses:**
```json
// First file
{
  "tool": "edit_buffer",
  "arguments": {
    "filepath": "main.lua",
    "lines": ["-- fixed content"],
    "save": true,
    "cursor_line": 15  // Show where the fix was made
  }
}

// Second file
{
  "tool": "edit_buffer",
  "arguments": {
    "filepath": "utils.lua",
    "lines": ["-- fixed content"],
    "save": true,
    "cursor_line": 42
  }
}
```

**User sees:**
- `main.lua` opens, shows fix, cursor at line 15
- `utils.lua` opens, shows fix, cursor at line 42
- Both files saved
- Can easily review both changes

### Example 3: Read Then Edit

**User:** "Add error handling to the parse function"

**Claude uses:**
```json
// First, read to understand current code
{
  "tool": "get_buffer_content",
  "arguments": {
    "bufnr": 1  // or open_buffer first
  }
}

// Then edit with error handling added
{
  "tool": "edit_buffer",
  "arguments": {
    "filepath": "parser.lua",
    "lines": ["-- enhanced content with error handling"],
    "save": true
  }
}
```

## Comparison: MCP vs Built-in Tools

| Operation | Built-in Tools | MCP Tools |
|-----------|---------------|-----------|
| Read file | `Read` tool → reads from disk | `get_buffer_content` → reads from Neovim buffer |
| Edit file | `Edit` tool → modifies disk, invisible | `edit_buffer` → modifies + focuses in Neovim |
| See changes | Manual `:e` reload needed | Instant, automatic |
| File focus | No control | Automatic focus |
| Cursor positioning | No control | Optional cursor_line |
| Save control | Automatic | Optional (default: save) |
| Real-time visibility | ❌ No | ✅ Yes |

## Additional Tools

While `edit_buffer` handles most use cases, other tools are available:

- **list_buffers** - See what's currently open
- **execute_command** - Run Neovim commands (e.g., `:split`, `:vsplit`)
- **get_cursor** / **set_cursor** - Fine cursor control
- **open_buffer** / **close_buffer** - Buffer management

## Best Practices

### ✅ Do This

```markdown
User: "Update config.lua with new settings"

Claude: I'll use edit_buffer to update the file so you can see the changes.
[Uses edit_buffer with full new content]
```

### ❌ Avoid This

```markdown
User: "Update config.lua with new settings"

Claude: I'll update the file.
[Uses Edit tool - changes hidden from user]
```

## Troubleshooting

### Changes Not Appearing?

1. Check Claude Code is using MCP tools:
   - Look for "edit_buffer" in the tool calls
   - If using "Edit" tool, remind Claude to use MCP tools

2. Verify MCP server is connected:
   - Claude Code shows "nvim-agent" in connected servers
   - Check `~/.claude/settings.json` has MCP config

3. Test manually:
   ```bash
   export NVIM_LISTEN_ADDRESS=/tmp/nvim.sock
   echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"edit_buffer","arguments":{"filepath":"test.txt","lines":["hello"]}}}' | luajit server.lua
   ```

### File Opens But Content Not Updated?

This shouldn't happen with `edit_buffer` as it directly sets buffer content.
If it does:
- Check for Lua errors in `:messages`
- Verify buffer is writable (not readonly)
- Check file permissions

### Multiple Windows/Splits?

`edit_buffer` focuses the current window. If you want splits:
1. Use `execute_command` with `:vsplit` first
2. Then use `edit_buffer`

Or ask Claude: "Open config.lua in a vertical split and edit it"

## Performance Notes

- **Latency:** 20-100ms per edit (shell exec overhead)
- **Buffer size:** Works well up to 10k lines
- **Multiple edits:** Each edit is a separate RPC call
- **User experience:** Feels instant for human interaction

## Future Enhancements

Potential improvements (not yet implemented):
- Incremental edits (modify ranges instead of full buffer)
- Streaming edits (show changes as they're generated)
- Diff-based updates (only send changed lines)
- Multiple buffer batch operations
- Async notifications when edits complete

## Summary

With the MCP tools, especially `edit_buffer`:
✅ All file edits are visible in real-time
✅ Buffers automatically focus
✅ User can see exactly what the agent is doing
✅ Natural workflow that feels like pair programming
✅ Agent controls what's visible and where cursor is

The key instruction in CLAUDE.md ensures Claude Code prefers MCP tools over filesystem tools, giving you full visibility into all file operations.
