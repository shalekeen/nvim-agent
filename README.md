# nvim-agent

A Neovim plugin to manage and interact with one or more terminal-based coding agents (Claude Code, etc.) inside Neovim. Each agent runs in its own terminal split, gets its own session directory, and is wired up to an MCP server that lets the agent control your buffers in real time.

## Features

- Run one or more coding agents side-by-side in dedicated terminal splits
- Per-session **flavors** and **checkpoints** — reusable system-prompt + user-notes presets
- Bundled **MCP server** so agents can read/write buffers, search files, and coordinate with peer agents directly through your editor
- Auto-injected context (open buffers, cursor, git status, diagnostics, tmux pane captures) before every prompt
- Multi-agent messaging: agents can send messages, broadcast status, and delegate work to one another
- Pluggable **adapter** interface — ships with a Claude Code adapter; add your own

## Requirements

- Neovim 0.10 or newer (the MCP server runs via `nvim -l`, using the LuaJIT bundled with Neovim — no external `luajit` binary required)
- An installed coding-agent CLI (e.g. `claude` for the bundled `claude_code` adapter)
- [`folke/which-key.nvim`](https://github.com/folke/which-key.nvim) — used to register the keymap groups
- [`romgrk/barbar.nvim`](https://github.com/romgrk/barbar.nvim) — used to pin agent terminal buffers to the left of the bufferline

## Installation (lazy.nvim / LazyVim)

Drop this into your `lua/plugins/` directory:

```lua
return {
  "shalekeen/nvim-agent",
  dependencies = {
    "folke/which-key.nvim",
    "romgrk/barbar.nvim",
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
| `auto_open` | `false` | When `true`, auto-launch the previously used flavor on Neovim startup (or show the picker on first run). When `false`, do nothing on startup — the user triggers `:NvimAgent` manually and is shown the full picker. |
| `base_dir` | `~/.nvim-agent` | Where session directories, flavors, and persisted state live. |
| `auto_write_context` | `true` | Refresh `ephemeral.json` when switching to an agent buffer. |
| `terminal.split_direction` | `"vertical"` | `"vertical"` or `"horizontal"`. |
| `terminal.split_size` | `0.4` | Fraction of the screen the agent split takes. |
| `agent_instruction_header` | (built-in) | Always appended after the base system prompt (whether that's the active flavor's `system_prompt.md` or `default_system_prompt`). Use this to layer cross-cutting instructions — e.g. "you're running inside Neovim via nvim-agent, here's how the context injection works" — on top of every agent's prompt. |
| `default_system_prompt` | (built-in) | System prompt seeded into new flavors. |

### Statusline component

`require("nvim-agent").statusline()` returns a short string identifying the current session's flavor and checkpoint, formatted as `Agent-<session_name>: <flavor> @ <checkpoint>` (e.g. `Agent-main: dev @ base`). It returns an empty string when there is no current session, so it's safe to drop into a global statusline:

```lua
vim.opt.statusline = "%f %m%r  %{%v:lua.require('nvim-agent').statusline()%}%=%y  %l:%c  %p%%"
```

## Usage

Once the plugin is loaded, all functionality lives behind the `:NvimAgent` command. With no argument, it toggles the current session's terminal split.

```
:NvimAgent             " toggle the current session's terminal (or open the picker if no session)
:NvimAgent open        " open the current session's terminal
:NvimAgent close       " close the current session's terminal
:NvimAgent toggle      " same as no-arg form
:NvimAgent refresh     " regenerate context (ephemeral.json etc.) for the current session
:NvimAgent flavor      " manage flavors (system prompt + user notes presets)
:NvimAgent checkpoint  " manage checkpoints within a flavor
:NvimAgent session     " create / list / switch between agent sessions
:NvimAgent agent       " spawn / send-message / delegate to peer agents
:NvimAgent template    " manage agent role templates
:NvimAgent role        " edit the role/expertise description for the current agent
:NvimAgent history     " view work history (agent [name] | workspace | project)
:NvimAgent workspace   " project-local workspace settings
:NvimAgent edit        " edit context files (prompt | notes | dirs)
:NvimAgent view        " view context files read-only (prompt | notes | dirs)
:NvimAgent dir         " open the active session dir in the explorer
:NvimAgent tmux        " capture a tmux pane into the agent's context
:NvimAgent setup       " re-run adapter setup (refresh ~/.claude/settings.json, hook script, CLAUDE.md block)
```

Several of these subcommands take a second-level action (e.g. `:NvimAgent flavor create <name>`, `:NvimAgent session new`, `:NvimAgent agent send <name> <msg>`). For the full nested grammar, see `lua/nvim-agent/commands.lua` — tab-completion also covers every nested form.

A `<leader>a` keymap group is also registered via which-key — see `lua/nvim-agent/keymaps.lua` for the full list.

## How context reaches the agent

### Environment variables

When the plugin spawns either the agent CLI (e.g. `claude`) or its MCP server, it injects the following variables into the subprocess environment:

| Var | Agent process | MCP server | Value |
| --- | :---: | :---: | --- |
| `NVIM_AGENT_ACTIVE_DIR` | ✓ | ✓ | `~/.nvim-agent/sessions/<pid>/<name>/active/` — this session's flavor files |
| `NVIM_AGENT_PROCESS_DIR` | ✓ | ✓ | `~/.nvim-agent/sessions/<pid>/` — shared per-Neovim state |
| `NVIM_AGENT_CWD` | ✓ | ✓ | `vim.fn.getcwd()` at session start |
| `NVIM_AGENT_BASE_DIR` | ✓ | ✓ | The configured `base_dir` (defaults to `~/.nvim-agent`) |
| `NVIM_AGENT_NVIM_ADDR` | – | ✓ | `vim.v.servername` — used by the MCP server to RPC into the parent Neovim |

Custom adapters can read these to find the right files (see `lua/nvim-agent/adapter/README.md`).

### The `UserPromptSubmit` hook

The `claude_code` adapter writes a small shell script to `~/.nvim-agent/hooks/claude_code_prompt.sh` and registers it as a `UserPromptSubmit` hook in two places:

- `~/.claude/settings.json` — global default
- `<session.dir>/mcp-settings.json` — per-session override (Claude Code is launched with `--mcp-config` pointing at this file)

Claude Code runs the hook before every prompt and prepends the hook's stdout to the user's message as additional context. The script reads files relative to `$NVIM_AGENT_ACTIVE_DIR`, `$NVIM_AGENT_PROCESS_DIR`, and `$NVIM_AGENT_CWD`.

### What the hook injects on each prompt

- **Session-scoped** (from `$NVIM_AGENT_ACTIVE_DIR`):
  - `.flavor_meta.json` — current flavor + checkpoint
  - `user_notes.md` — standing user instructions
  - `persistent_dirs.json` — pinned code paths
  - `role.md` — agent's role description (workspace mode)
- **Project root**: `PROJECT.md` (if present) — shared by all agents in the project
- **Process-shared** (from `$NVIM_AGENT_PROCESS_DIR`):
  - `ephemeral.json` — open buffers, cursor, git status, diagnostics, quickfix
  - `tmux_captures.json` — captured tmux pane content (if any)
- **Project-local** (from `$NVIM_AGENT_CWD/.nvim-agent/`):
  - Pending messages addressed to this session
  - Status + role summary of all peer agents
  - Last 40 lines of this agent's persistent history log

Other adapters can opt into the same flow by emitting a hook script and registering it however the target CLI expects.

## Two ways to use nvim-agent

- **Standalone agent** — pick a flavor at startup and you're handed a single agent split. No project files involved; everything lives under `~/.nvim-agent/`. This is the default flow when you launch the plugin in any directory.
- **Project workspace** — run `:NvimAgent workspace init` once per project to create a checked-in directory of agent definitions (system prompts, user notes, roles per agent) plus declarative `workspaces/<name>.json` files that launch a named set of agents together. The init prompt suggests `.nvim-workspace/` as the directory name but you can use any name. Workspace definitions live in your repo; runtime state stays under `<cwd>/.nvim-agent/` (gitignored).

You can mix the two — the picker on `:NvimAgent` always offers "Open standalone agent" alongside any workspaces it finds in the current project.

## Workspaces

Workspaces are the project-mode answer to "I want a fixed, reproducible set of agents to launch every time I open this repo." A workspace is a checked-in declaration of *which agents exist in this project, what each one does, and which group of them launches together*. Open the project, hit `:NvimAgent`, pick the workspace, and every agent in it spins up in its own terminal split — each pre-loaded with its own system prompt, role, and notes.

### Initializing a workspace

Run once per project:

```
:NvimAgent workspace init
```

You'll be prompted for a directory name (default: `.nvim-workspace`). The plugin creates two trees:

- `<cwd>/<def_dir>/` — checked into git. Holds agent definitions and workspace manifests.
- `<cwd>/.nvim-agent/` — gitignored. Holds runtime state (peer discovery, messages, history, triggers).

The choice of `<def_dir>` is recorded in `<cwd>/.nvim-agent/config.json` so the plugin can find it on later launches.

### Defining agents

```
:NvimAgent agent new        " interactive: prompts for a name, opens the new agent's def dir
:NvimAgent agent list       " browse all agents in the current workspace
:NvimAgent agent save       " save the current session's context files back to its def dir
:NvimAgent agent remove     " delete an agent definition
:NvimAgent agent set-template  " interactive: pick an agent, then pick a template to link
```

Each agent lives at `<cwd>/<def_dir>/agents/<name>/` and may contain:

| File | Purpose |
| --- | --- |
| `system_prompt.md` | The agent's instructions (only required file) |
| `user_notes.md` | Standing per-agent user notes |
| `persistent_dirs.json` | Pinned code paths the agent should know about: `[{ tag, path, description }]` |
| `.flavor_meta.json` | Flavor + checkpoint metadata (optional — workspace agents don't usually need this) |
| `role.md` | One-line role description used for peer discovery (e.g. "frontend lead", "test runner") |
| `.agent_meta.json` | If present and contains `{ "template": "<name>" }`, the agent inherits from a global template (see below) |

Editing any of these files takes effect on the agent's **next** session launch.

### Defining a launchable workspace

A "workspace" in the launcher sense is a manifest at `<cwd>/<def_dir>/workspaces/<name>.json` that names which agents launch together:

```json
{
  "name": "feature-dev",
  "agents": [
    { "name": "Senior SWE 1", "role": "lead implementer" },
    { "name": "Senior SWE 2", "role": "reviewer" },
    { "name": "QA Bot",       "role": "writes tests" }
  ]
}
```

Manage them with:

```
:NvimAgent workspace new           " interactive: prompts for a name and selects agents
:NvimAgent workspace launch        " picker over manifests; bootstraps init+new if empty
:NvimAgent workspace launch <name> " launch a named workspace directly
:NvimAgent workspace list          " browse all workspace manifests in this project
:NvimAgent workspace edit          " open the current workspace manifest
:NvimAgent workspace save          " save the live session set as a workspace
:NvimAgent workspace remove        " delete a workspace manifest
```

The `launch` subcommand is also bound to `<leader>awL`. Use it to spin up a workspace when you already have a standalone agent running (for example, when `auto_open=true` resumed your last standalone flavor and you want to drop into multi-agent mode without closing the current session).

A project can hold any number of workspaces — different `<name>.json` files for different launch sets (e.g. `quick-fix.json` with one agent, `full-team.json` with five).

### Launching

When `auto_open` is enabled or you run `:NvimAgent` manually, the picker offers one entry per workspace it finds in the current project, plus the standalone fallback. Picking a workspace runs `workspace_launch` (`init.lua:550`):

1. Writes project permissions for the active adapter (so agents don't get permission-prompted on every read/write).
2. Initializes the runtime dir at `<cwd>/.nvim-agent/`.
3. For each agent in the manifest, in order:
   - Creates a session with the agent's name.
   - Loads the agent's content into the session's `active/` dir: template files first (if linked), then any agent-specific overrides on top.
   - If the agent has no `.flavor_meta.json`, prompts for a flavor + checkpoint before continuing.
   - Spawns a terminal split running the configured adapter CLI (e.g. `claude`).

Sessions are processed sequentially so that flavor pickers don't overlap.

### Roles and peer discovery

The hook script (see "How context reaches the agent" above) reads `<cwd>/.nvim-agent/status/*.json` and `<cwd>/.nvim-agent/messages/<agent>.md` before every prompt and feeds the result to the agent. Each agent's role description from `role.md` is included in the peer summary, so a multi-agent workspace inherently tells every agent who else is around and what they're doing. The `send_message`, `update_status`, and `read_messages` MCP tools are how agents talk to each other — see `lua/nvim-agent/mcp/tools.lua` for the full multi-agent tool surface.

### Project permissions

```
:NvimAgent workspace permissions
```

Asks the active adapter to write a `.claude/settings.json` (or equivalent) inside the project so the agent CLIs running in this repo don't trigger permission prompts on every file/bash operation. Run this once after init; `workspace_launch` also calls it implicitly on every launch.

### Agent templates

Templates let you write a system prompt + user notes once and reuse them across many agents and projects. Useful when you have a stock persona — "Senior SWE", "test writer", "rubber duck" — that you want to spawn in lots of different workspaces.

```
:NvimAgent template create   " create a template from an existing agent's def dir (interactive)
:NvimAgent template list     " browse global templates
:NvimAgent template remove   " delete a template (interactive picker)
```

**Where templates live:** `~/.nvim-agent/agent_templates/<name>/`. One canonical copy per template, global to the user (not project-scoped).

**Linking agents to templates:** an agent inherits from a template by having `.agent_meta.json` in its def dir contain `{ "template": "<template_name>" }`. The link is by **name** — the template files are *not* duplicated into the agent's def dir. Use `:NvimAgent agent set-template ...` to wire this up, or write the JSON by hand.

**How loading works at session start** (`agent_load_content` in `workspace.lua:310`):

1. Read the agent's `.agent_meta.json`.
2. If `template` is set, copy the template's files (`system_prompt.md`, `user_notes.md`, `persistent_dirs.json`, `role.md`) from `~/.nvim-agent/agent_templates/<name>/` into the session's `active/` dir.
3. Overlay any agent-specific files from `<cwd>/<def_dir>/agents/<agent>/` on top — agent files win on conflict.

**Concrete example.** You define a `Senior SWE` template, then create two agents in your workspace — `Senior SWE 1` and `Senior SWE 2` — both with `.agent_meta.json` pointing at the same template. On disk:

- One global copy of the template at `~/.nvim-agent/agent_templates/Senior SWE/` (no duplication).
- Two tiny `.agent_meta.json` files in `<def_dir>/agents/Senior SWE 1/` and `<def_dir>/agents/Senior SWE 2/` — that's the entire on-disk overhead per linked agent (plus any agent-specific overrides you choose to add).
- At runtime, two ephemeral copies live under `~/.nvim-agent/sessions/<pid>/Senior SWE 1/active/` and `…/Senior SWE 2/active/`. These are the working copies the hook script feeds to each agent via `$NVIM_AGENT_ACTIVE_DIR`. They die with the Neovim process.

**Propagation:** editing the template's `system_prompt.md` propagates to both agents on their **next** session launch. Live sessions keep their already-copied files until restart. Editing per-agent overrides only affects that agent.

## How nvim-agent uses the filesystem

There are three roots, each with a different lifetime and ownership.

### 1. Global runtime — `~/.nvim-agent/` (per user, persistent)

```
~/.nvim-agent/
├── sessions/<pid>/                    # one process dir per running Neovim (ephemeral)
│   ├── ephemeral.json                 # editor state, shared by all sessions in this nvim
│   ├── tmux_captures.json             # captured tmux panes, shared
│   └── <session_name>/
│       ├── active/                    # the per-session context dir
│       │   ├── system_prompt.md
│       │   ├── user_notes.md
│       │   ├── persistent_dirs.json
│       │   └── .flavor_meta.json      # which flavor + checkpoint this session loaded
│       └── mcp-settings.json          # adapter-specific MCP wiring
├── hooks/                             # adapter hook scripts
│   └── claude_code_prompt.sh          # UserPromptSubmit hook for the Claude Code adapter
├── agent_templates/<name>/            # reusable agent role templates
│   ├── system_prompt.md
│   ├── user_notes.md
│   ├── persistent_dirs.json
│   └── role.md
├── <flavor_name>/                     # one directory per flavor, sharable across projects
│   ├── system_prompt.md
│   ├── user_notes.md
│   ├── persistent_dirs.json
│   └── checkpoints/<name>/            # optional named variants of the flavor
│       ├── system_prompt.md
│       ├── user_notes.md
│       └── persistent_dirs.json
└── last_flavor.json                   # last-used flavor (powers "Use Active" + auto_open)
```

Flavors live as top-level directories under `~/.nvim-agent/`, alongside the `sessions/`, `hooks/`, and `agent_templates/` metadata dirs. The names `active`, `sessions`, `hooks`, and `agent_templates` are reserved and cannot be used as flavor names.

`sessions/<pid>/` is ephemeral — entries die with the Neovim process. Everything else persists across restarts.

### 2. Project-local runtime — `<cwd>/.nvim-agent/` (gitignored)

Created on demand when a workspace is initialised or when peer-agent messaging fires. **Add `.nvim-agent/` to your project's `.gitignore` — it holds runtime state, not configuration.**

```
<cwd>/.nvim-agent/
├── config.json                        # { "workspace_def_dir": "<rel-path>" }
├── status/<agent>.json                # peer discovery: each running agent advertises here
├── messages/<agent>.md                # mailboxes for inter-agent send_message()
├── history/<agent>.md                 # persistent per-agent work logs
└── triggers/<agent>                   # wakeup signals (touch a file → agent resumes)
```

### 3. Workspace definitions — `<cwd>/<def_dir>/` (project workspaces only, checked into git)

Only present in projects you've initialised with `:NvimAgent workspace init`. The `<def_dir>` name is whatever you choose at init time; the choice is recorded in `.nvim-agent/config.json`. Standalone agent use doesn't touch this directory.

```
<cwd>/<def_dir>/
├── agents/<name>/                     # one directory per agent, committed to git
│   ├── system_prompt.md
│   ├── user_notes.md
│   ├── persistent_dirs.json
│   ├── .flavor_meta.json              # flavor/checkpoint metadata for this agent
│   └── role.md                        # role description used for peer discovery
└── workspaces/<name>.json             # { "name": ..., "agents": [{ "name": ..., "role": ... }] }
```

## Custom adapters

To wire up a different agent CLI, implement an adapter that inherits from `require("nvim-agent.adapter").base`. See `lua/nvim-agent/adapter/README.md` for the full interface and a worked example based on the bundled Claude Code adapter.

## License

Apache 2.0 — see `LICENSE`.
