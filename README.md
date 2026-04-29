# nvim-agent

A Neovim plugin to manage and interact with one or more terminal-based coding agents (Claude Code, etc.) inside Neovim. Each agent runs in its own terminal split, gets its own session directory, and is wired up to an MCP server that lets the agent control your buffers in real time.

## Features

- Run one or more coding agents side-by-side in dedicated terminal splits
- Per-session **flavors** and **checkpoints** — reusable system-prompt + user-notes presets
- Built-in **MCP server** so agents can read/write buffers, search files, and coordinate with peer agents directly through your editor
- Auto-injected context (open buffers, cursor, git status, diagnostics, tmux pane captures) before every prompt
- Multi-agent messaging: agents can send messages, broadcast status, and delegate work to one another
- Pluggable **adapter** interface — ships with a Claude Code adapter; add your own

## Requirements

- Neovim 0.10 or newer
- LuaJIT (bundled with Neovim) — used to run the MCP server
- An installed coding-agent CLI (e.g. `claude` for the bundled `claude_code` adapter)
- [`folke/which-key.nvim`](https://github.com/folke/which-key.nvim) — **required** (used to register the keymap groups)
- [`romgrk/barbar.nvim`](https://github.com/romgrk/barbar.nvim) — optional (agent buffers are auto-pinned to the left when present)

## Installation (lazy.nvim / LazyVim)

Drop this into your `lua/plugins/` directory:

```lua
return {
  "shalekeen/nvim-agent",
  dependencies = {
    "folke/which-key.nvim",
    "romgrk/barbar.nvim", -- optional
  },
  cmd = { "NvimAgent" },
  event = "VeryLazy",
  opts = {
    adapter = "claude_code",
    auto_open = true,
  },
  config = function(_, opts)
    require("nvim-agent").setup(opts)
  end,
}
```

If you are developing locally, point `dir` at your checkout instead of using a remote spec:

```lua
return {
  dir = "~/Desktop/projects/nvim-agent",
  name = "nvim-agent",
  -- ...rest as above
}
```

## Configuration

`setup()` accepts the following options (see `lua/nvim-agent/config.lua` for the full default table):

| Option | Default | Description |
| --- | --- | --- |
| `adapter` | `nil` | Adapter to use. Built-in: `"claude_code"`. May also be a custom adapter table. |
| `auto_open` | `false` | Open the agent terminal automatically on Neovim startup. |
| `base_dir` | `~/.nvim-agent` | Where session directories, flavors, and persisted state live. |
| `auto_write_context` | `true` | Refresh `ephemeral.json` when switching to an agent buffer. |
| `terminal.split_direction` | `"vertical"` | `"vertical"` or `"horizontal"`. |
| `terminal.split_size` | `0.4` | Fraction of the screen the agent split takes. |
| `agent_instruction_header` | (built-in) | Preamble injected at the top of every agent's system prompt. |
| `default_system_prompt` | (built-in) | System prompt seeded into new flavors. |

## Usage

Once the plugin is loaded, all functionality lives behind the `:NvimAgent` command:

```
:NvimAgent flavor      " manage flavors (system prompt + user notes presets)
:NvimAgent checkpoint  " manage checkpoints within a flavor
:NvimAgent session     " create/list/switch between agent sessions
:NvimAgent agent       " spawn / send-message / delegate to peer agents
:NvimAgent template    " manage agent role templates
:NvimAgent workspace   " project-local workspace settings
:NvimAgent edit        " edit context files
:NvimAgent view        " view context files (read-only)
:NvimAgent dir         " open the active session dir
:NvimAgent tmux        " capture a tmux pane into the agent's context
```

A `<leader>a` keymap group is also registered via which-key — see `lua/nvim-agent/keymaps.lua` for the full list.

## How sessions are laid out on disk

```
~/.nvim-agent/
├── sessions/<pid>/                    # one process dir per running Neovim
│   ├── ephemeral.json                 # editor state, shared by all sessions
│   ├── tmux_captures.json             # captured tmux panes, shared
│   └── <session_name>/
│       ├── active/                    # the per-session context dir
│       │   ├── system_prompt.md
│       │   ├── user_notes.md
│       │   ├── persistent_dirs.json
│       │   └── .flavor_meta.json
│       └── mcp-settings.json          # adapter-specific MCP wiring
├── flavors/                           # reusable presets
└── last_flavor.json                   # last-used flavor (for the default option on startup)
```

## Custom adapters

To wire up a different agent CLI, implement an adapter that inherits from `require("nvim-agent.adapter").base`. See `lua/nvim-agent/adapter/README.md` for the full interface and a worked example based on the bundled Claude Code adapter.

## License

Apache 2.0 — see `LICENSE`.
