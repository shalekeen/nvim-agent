# Quick Start: Real-Time Editing with MCP

## What You Get

✅ **Real-time visibility** - See all of Claude's file edits instantly in Neovim
✅ **Automatic focus** - Edited files automatically open and focus
✅ **Cursor positioning** - See exactly where changes were made
✅ **No manual reloading** - Everything updates automatically

## Setup (One-Time)

1. **Restart Neovim** - This runs the adapter setup automatically

2. **Verify setup** - Check that MCP server is configured:
   ```bash
   cat ~/.claude/settings.json | jq '.mcpServers."nvim-agent"'
   ```

   Should show:
   ```json
   {
     "command": "/usr/bin/nvim",
     "args": ["-l", "/path/to/nvim-agent/lua/nvim-agent/mcp/server.lua"],
     "env": {
       "NVIM_AGENT_NVIM_ADDR": "/tmp/nvim.xxx.0"
     }
   }
   ```

   (`command` is whatever `vim.v.progpath` resolves to in your running Neovim — typically `/usr/bin/nvim` or the binary your package manager installed.)

3. **Check instructions** - Verify CLAUDE.md has MCP documentation:
   ```bash
   grep -A 5 "edit_buffer" ~/.claude/CLAUDE.md
   ```

## Usage

### Launch Claude Code

From within Neovim:
```vim
:lua require("nvim-agent.terminal").toggle("claude_code")
```

Or use your configured keybinding.

### Ask Claude to Edit Files

Just ask naturally - Claude will use the MCP tools automatically:

**Examples:**

```
"Add error handling to parser.lua"
"Refactor the database connection code in config.lua"
"Create a new function in utils.lua to format dates"
"Fix the typo on line 42 of main.lua"
```

### What You'll See

1. **File opens** (if not already visible)
2. **Content updates** instantly
3. **Cursor moves** to the relevant location
4. **File saves** automatically
5. **Window focuses** on the edited buffer

All in real-time as Claude works!

## How It Works (Under the Hood)

```
You: "Update config.lua"
   ↓
Claude Code: Uses edit_buffer MCP tool
   ↓
MCP Server: Sends RPC command to Neovim
   ↓
Neovim: Opens file → Applies changes → Saves → Focuses
   ↓
You: See the changes instantly!
```

## The Magic Tool: edit_buffer

This is the primary tool Claude uses for all file editing:

```javascript
edit_buffer({
  filepath: "path/to/file.lua",
  lines: ["new", "content", "here"],
  save: true,              // default: true
  cursor_line: 10          // optional
})
```

**All in one operation:**
- Opens/switches to file
- Updates content
- Saves file
- Focuses window
- Positions cursor

## Verifying It's Working

### Test 1: Simple Edit

In Claude Code, try:
```
Use edit_buffer to create a file called test.txt with the content "Hello World"
```

You should see:
- `test.txt` appears as a new buffer
- Contains "Hello World"
- File is saved
- Buffer has focus

### Test 2: Multi-File Edit

```
Create three files: a.txt, b.txt, c.txt with numbers 1, 2, 3
```

You should see:
- Each file opens in sequence
- Each shows its respective number
- All are saved
- Final file (c.txt) has focus

### Test 3: List What's Open

```
Use list_buffers to show me what files are currently open
```

You should see:
- JSON output listing all open buffers
- Including the test files just created

## Comparison: Before vs After

### Before (Built-in Tools)

```
You: "Update config.lua"
Claude: [Uses Edit tool]
You: [Don't see any changes]
You: [Manually run :e to reload]
You: [Now see changes]
```

### After (MCP Tools)

```
You: "Update config.lua"
Claude: [Uses edit_buffer]
You: [Immediately see file open and update]
You: [Changes are already saved and focused]
```

## All Available Tools (9 Total)

### Primary Tools
1. **edit_buffer** 🌟 - Complete file editing with focus
2. **get_buffer_content** - Read buffer contents
3. **list_buffers** - Show all open buffers
4. **execute_command** - Run Neovim commands

### Advanced Tools
5. **open_buffer** - Open a file
6. **set_buffer_content** - Write to buffer
7. **close_buffer** - Close a buffer
8. **set_cursor** - Move cursor
9. **get_cursor** - Get cursor position

## Common Workflows

### Reading a File

```
"Show me the contents of config.lua"
```
Claude uses: `get_buffer_content` or `open_buffer` then `get_buffer_content`

### Editing a File

```
"Add logging to the main function in app.lua"
```
Claude uses: `edit_buffer` with the updated content

### Creating a New File

```
"Create a new file helpers.lua with utility functions"
```
Claude uses: `edit_buffer` with the new filepath

### Multiple Edits

```
"Update all the config files to use the new API endpoint"
```
Claude uses: Multiple `edit_buffer` calls, one per file

### Neovim Commands

```
"Split the window and open config.lua on the right"
```
Claude uses: `execute_command` with "vsplit", then `edit_buffer`

## Tips

### Explicit Instructions

If Claude isn't using MCP tools, remind it:
```
"Use the edit_buffer MCP tool to update config.lua"
```

### See the Process

Ask Claude to explain what it's doing:
```
"Update config.lua and tell me which MCP tool you're using"
```

### Position Matters

Request cursor positioning:
```
"Update config.lua and position the cursor at the new function"
```

### Save Control

Prevent auto-save if needed:
```
"Use edit_buffer with save=false to preview changes first"
```

## Troubleshooting

### "Tool not found" error
- Restart Neovim to reload adapter
- Check MCP server in settings.json

### Changes not visible
- Check Claude is using "edit_buffer" (not "Edit")
- Verify `NVIM_AGENT_NVIM_ADDR` (in `~/.claude/settings.json`) matches `:echo v:servername`

### Can't connect to Neovim
- Check Neovim is running
- Verify `v:servername` is set (`:echo v:servername`)
- Test manually: `nvim --server /tmp/nvim.sock --remote-expr "1+1"`

## Next Steps

Now you're ready to:
1. ✅ Edit files with real-time visibility
2. ✅ See all changes as they happen
3. ✅ Let Claude control your editor naturally
4. ✅ Pair program with AI in your own environment

Just launch Claude Code and start asking for edits - everything will appear in Neovim automatically!

## More Information

- **Full tool documentation**: `nvim-agent/mcp/README.md`
- **Implementation details**: `nvim-agent/mcp/IMPLEMENTATION_SUMMARY.md`
- **Real-time editing guide**: `nvim-agent/mcp/REALTIME_EDITING.md`
- **Testing procedures**: `nvim-agent/mcp/TESTING.md`
- **Adapter interface**: `nvim-agent/adapter/README.md`
