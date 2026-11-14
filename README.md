# nvim-agent

A Neovim plugin that hosts one or more terminal-based coding agents (Claude Code, etc.) inside Neovim. You define **agents** once, globally; a **workspace** is the set of agents you run together in a project. Every agent gets its own terminal split and is wired to a bundled MCP server that lets it edit your buffers and talk to its peers in real time.

![nvim-agent multi-agent demo](docs/nvim-agent-multiagent-demo.gif)

## Features

- Run one or more coding agents side-by-side in dedicated terminal splits
- A **global agent library**: each agent is a role, a system prompt, standing notes, and pinned dirs, reusable across every project
- **Workspaces** per project that remember which agents run together, saved automatically on every change
- An **ephemeral workspace** that is created the first time you open a project, so you can start in seconds and promote it to a named workspace later
- Bundled **MCP server** so agents can read/write buffers, search files, and coordinate with peers directly through your editor
- Auto-injected context (open buffers, cursor, git status, diagnostics, tmux pane captures) before every prompt, shared by every agent in the Neovim instance
- Multi-agent messaging: agents send messages, broadcast status, delegate work, and can spawn or relaunch each other
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
| `auto_open` | `false` | When `true`, show the startup picker (or, on first launch in a directory, the agent picker for the ephemeral workspace) as soon as Neovim starts. When `false`, nothing happens until you run `:NvimAgent`. |
| `base_dir` | `~/.nvim-agent` | Where the agent library, session dirs, and hook scripts live. |
| `auto_write_context` | `true` | Refresh `ephemeral.json` when switching to an agent buffer. |
| `terminal.split_direction` | `"vertical"` | `"vertical"` or `"horizontal"`. |
| `terminal.split_size` | `0.4` | Fraction of the screen the agent split takes. |
| `terminal.scrollback` | `100000` | Lines of terminal scrollback kept per agent buffer (Neovim's default is 10000; 100000 is its maximum). The Claude Code adapter also launches the CLI with `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`: its fullscreen renderer draws on the alternate screen, for which Neovim keeps no scrollback, so inside Neovim the inline renderer is forced regardless of your global `tui` setting. |
| `terminal.grid_columns` | `4` | Maximum agents per row when arranging all agents in a grid (`:NvimAgent arrange`, `<leader>a=`). |
| `terminal.title` | `"{name}"` | Tab title of an agent terminal in barbar or any bufferline. Placeholders: `{name}` (session), `{agent}`, `{workspace}`. Buffers are named like native terminals, `term://<cwd>//<pid>:<title>`, so only the title is displayed. Separately, every launch names the CLI's own conversation `"<agent> <YYYY-MM-DD HH:MM>"` through the adapter's `rename_conversation` hook; with Claude Code that is `--name`, shown in its prompt box and `/resume` picker. |
| `nvim_agent_preamble` | (built-in) | Layer 1 of the composed system prompt — the CLI-neutral runtime contract from nvim-agent (directory layout, context-file catalogue, MCP tools, coordination rules). Always emitted first; cannot be removed by editing an agent. The CLI-specific part (how context is delivered, which native tools to avoid) is layer 1b and comes from the adapter. |
| `default_system_prompt` | (built-in) | The `system_prompt.md` a newly defined agent starts with. Also the fallback when an agent's prompt is empty. |

### System prompt composition

Every session's system prompt is built from these layers, joined by blank lines. Empty layers are dropped:

1. **`nvim_agent_preamble`** (config option above) — the plugin's CLI-neutral runtime contract. Tells the agent about the directory layout, the context files, the MCP tools, and multi-agent coordination. Always present so editing an agent can't remove it.
1b. **Adapter context contract** (`adapter:get_context_contract()`) — how context actually reaches the agent under the CLI in use. The bundled Claude Code adapter describes its `UserPromptSubmit` hook and tells the agent not to use Claude Code's built-in file tools; the base adapter default tells a hook-less CLI to read the files on demand.
2. **`role.md`** — the agent's role, rendered as a "Your role" section. Every agent has one. It steers the agent's own behaviour from the first turn and is what other agents see when deciding whom to delegate to.
3. **`system_prompt.md`** — the agent's behaviour prompt. Defaults to `default_system_prompt` when empty.

### Statusline component

`require("nvim-agent").statusline()` returns `Agent-<session>: <agent> @ <workspace>`, with a `+` after the agent name when the session has workspace overrides and an `(exited)` suffix when the agent's CLI is not running. It returns an empty string when there is no current session, so it's safe to drop into a global statusline:

```lua
vim.opt.statusline = "%f %m%r  %{%v:lua.require('nvim-agent').statusline()%}%=%y  %l:%c  %p%%"
```

## Concepts

**Agents** are global. One lives at `~/.nvim-agent/agents/<name>/` and consists of exactly four things, plus an optional fifth:

| File | Purpose |
| --- | --- |
| `role.md` | **Required.** A short description of what this agent does. It opens the agent's system prompt, so it guides the agent's own behaviour, and it is published to peers via status files, so other agents use it to decide what to delegate to this one. |
| `system_prompt.md` | The behaviour prompt. Seeded from `default_system_prompt`. |
| `user_notes.md` | Standing notes and constraints. |
| `persistent_dirs.json` | Pinned code paths: `[{ "tag", "path", "description" }]`. |
| `permissions.json` | Optional, adapter-specific tool permissions (see the adapter README). |
| `config.json` | Runtime behaviour of the agent (see below). |

**Agent runtime config.** `config.json` is loaded alongside the other files, mirrored into the session, and overridable per workspace like everything else (`:NvimAgent edit config` edits the live member's copy and saves it as an override). Keys:

```json
{
  "inbox_wakeups": true,
  "inbox_wakeup_interval": 30,
  "history": "persistent",
  "periodic": [
    { "prompt": "Summarise what you have done since your last summary and log it with log_work.", "interval": 900 },
    { "prompt": "Check the test suite still passes.", "interval": 1800, "when": "always" }
  ]
}
```

- `inbox_wakeups` (default `true`): nvim-agent periodically nudges an idle agent whose mailbox or trigger file has new content so it resumes work. Set `false` for an agent that should act only when addressed directly; `trigger_agent` wakes still reach it, and messages still arrive in its context on its next prompt.
- `inbox_wakeup_interval` (default `30`): seconds between those checks for this agent, minimum 5. An agent is nudged only if it produced no terminal output for a whole interval and has something pending, so `300` means at most one nudge every five minutes.
- `history` (default `"persistent"`): `"fresh"` removes the entries this Neovim instance wrote for the agent, with their index and topic links, every time its CLI launches, restarts included, so each start has a clean log. Entries written by another instance running the same workspace are left alone. Use it for agents whose past work should never colour a new session.
- `conversation` (default `"resume"`): `"fresh"` starts a new CLI conversation on every launch of the agent instead of resuming the one recorded in the workspace manifest. Use it for agents whose previous conversation should never carry over.
- `periodic` (default `[]`): prompts typed into the agent's terminal on a schedule. Each entry needs a `prompt` and an `interval` in seconds (minimum 5), and may set `when` to `"idle"` (the default: send only if the agent produced no terminal output for a whole interval, so a prompt never interrupts work in progress) or `"always"`. Each entry keeps its own clock. Invalid entries are dropped.

Unknown keys are ignored and invalid values fall back to the defaults. Edits to the live copy take effect without a relaunch for `inbox_wakeups`, `inbox_wakeup_interval` and `periodic`; `history` is applied at the next launch.

Agents created at runtime by the `spawn_agent` MCP tool land in `~/.nvim-agent/agents/spawned/<name>/` and are listed in their own section so they don't crowd out your own; copy one with `:NvimAgent agent copy` to adopt it. Copying is also how you make a permanently different variant of an agent. For project-specific tweaks you don't need a copy: see overrides below.

**Workspaces** are per project. A workspace is a manifest at `<cwd>/.nvim-agent/workspaces/<name>/workspace.json` listing which agents run together:

```json
{
  "name": "feature-dev",
  "agents": [
    { "name": "Senior SWE", "agent": "Senior SWE", "conversation": "Senior SWE 2026-11-14 09:12" },
    { "name": "Senior SWE-2", "agent": "Senior SWE", "conversation": "Senior SWE-2 2026-11-14 09:12" },
    { "name": "QA", "agent": "QA" }
  ]
}
```

Each member also records the title of its CLI **conversation**, `"<name> <YYYY-MM-DD HH:MM>"` from the launch that created it. Every later launch of that member, in a new Neovim or after a restart, resumes that conversation through the adapter instead of starting a new CLI session, so the agent keeps its context. When nothing is recorded, or the CLI no longer has the conversation, a new one is started and its title recorded; the notification says which happened. `:NvimAgent agent fresh [name]` (`<leader>aaf`) forgets the recorded title and relaunches into a new conversation. An agent whose `config.json` sets `"conversation": "fresh"` always starts new. Resuming is a per-adapter capability: the Claude Code adapter checks its session store for the title and launches with `--resume`; an adapter without the hook starts new every time.

Each entry pairs a **session name** (unique within the workspace, what peers address) with the **global agent** it is built from, so the same agent can run twice. Manifests are written automatically whenever an agent is added or removed; there is no save step. The `.nvim-agent/` directory is runtime state and should be gitignored.

The **ephemeral workspace** is the one named `ephemeral`. It is created automatically the first time you launch nvim-agent in a directory, saved like any other, and offered as "Resume" on later launches. Promote it to a named workspace with `:NvimAgent workspace save-as`.

**Overrides** are how one workspace customises an agent without touching the global definition. A member may override any of its agent's files for this workspace only; the override lives at `<cwd>/.nvim-agent/workspaces/<workspace>/<session>/<file>`. At launch the global agent is mirrored into the session's `active/` dir first and any overrides are laid on top, so the hook sees the override whenever one exists and the global file otherwise. The first time you edit a context file from a live session, whether through `:NvimAgent edit notes`, `dir add`, the notes keymaps, or simply saving the file, the override is created from the session's current content and the edit lands there. The global agent is never written by a session edit. `:NvimAgent agent push` promotes a member's current files to the global agent and clears its overrides; `agent reset` drops overrides and reloads from the global; `agent overrides` shows what each member overrides. The statusline marks a session with overrides with a `+` after the agent name. The ephemeral workspace supports overrides exactly like a named one, and they travel with it when you promote it. Overrides are keyed by session name, so two copies of the same agent in one workspace each keep their own.

**Sessions** are live agents in this Neovim instance. A session's `active/` dir is the effective view of its agent: global files plus this workspace's overrides. **Membership and liveness are separate.** If an agent's CLI exits, whether you typed `/exit` or it crashed, the session is marked exited and its status file is removed so peers stop delegating to it, but it stays in the workspace. Relaunch it with `:NvimAgent agent restart`, by opening it, or by having a peer call `spawn_agent` with its name. `:NvimAgent agent stop` does the same deliberately. Only `:NvimAgent agent remove` takes an agent out of the workspace, and that also deletes its overrides.

## Usage

All functionality lives behind the `:NvimAgent` command. With no argument it toggles the current session's terminal, or opens the startup picker when no workspace is live.

### Startup

On the first launch in a directory there is nothing to pick, so you go straight into choosing agents for the ephemeral workspace: add agents from the library, define new ones on the spot, then launch. On later launches the picker offers:

- **Resume ephemeral workspace** — relaunch the agents you had last time
- **New workspace** — name it, pick its agents, launch
- **Load '\<name\>'** — one entry per saved workspace

Loading a workspace while another is live asks before stopping the running agents.

### Commands

```
:NvimAgent                       " toggle current terminal, or open the startup picker
:NvimAgent open | close | toggle
:NvimAgent arrange               " arrange every running agent in a uniform grid, ≤4 per row (re-flows in place on repeat)
:NvimAgent open all              " same as arrange
:NvimAgent close all             " hide every agent window (processes keep running)
:NvimAgent status                " team overview: state, role, task, mail, overrides per member
:NvimAgent send [name] [text]    " type a line into an agent's terminal
:NvimAgent refresh               " regenerate ephemeral.json

:NvimAgent workspace new         " name → pick agents → launch
:NvimAgent workspace load [name] " load a saved workspace (picker without a name)
:NvimAgent workspace list
:NvimAgent workspace remove [name]
:NvimAgent workspace rename [old] [new]
:NvimAgent workspace save-as [name]   " promote the live (ephemeral) workspace

:NvimAgent agent add [agent] [as-name]  " add a library agent to the live workspace and launch it
:NvimAgent agent remove [name]          " stop it, drop it from the workspace, delete its overrides
:NvimAgent agent stop [name]            " stop its CLI; it stays a member
:NvimAgent agent restart [name]         " relaunch an exited member (resumes its conversation)
:NvimAgent agent fresh [name]           " forget the recorded conversation and relaunch into a new one
:NvimAgent agent push [name]            " promote a member's files to the global agent, clear overrides
:NvimAgent agent overrides              " show which files each member overrides
:NvimAgent agent reset [name] [file]    " drop one/all overrides and reload from the global agent
:NvimAgent agent define                 " new global agent: name → role → opens its prompt
:NvimAgent agent copy [src] [dst]       " duplicate a global agent (project-specific variant / adopt a spawned one)
:NvimAgent agent edit [name]            " open a global agent's four files in a grid
:NvimAgent agent delete [name]
:NvimAgent agent list

:NvimAgent session list | switch [name|n]

:NvimAgent edit prompt | notes | dirs | role | config   " edit the current session's files (saved as a workspace override)
:NvimAgent view prompt | notes | dirs | role | config
:NvimAgent dir add <tag> <path> <description> | dir remove <tag>
:NvimAgent tmux add [lines] | clear | view
:NvimAgent history agent [name] | workspace | project | open
:NvimAgent setup                 " re-run adapter setup (hook script etc.)
```

Tab-completion covers every nested form, including agent, member, workspace and session names.

### Keymaps

A `<leader>a` group is registered via which-key. The most used bindings:

| Keys | Action |
| --- | --- |
| `<leader>a1` … `<leader>a9` | Jump to the nth agent (relaunches it if exited) |
| `<leader>al` / `<leader>aL` | Switch agent (picker) / list sessions |
| `<leader>a=` (or `<leader>aG`) / `<leader>aH` | Arrange every running agent in a uniform grid of at most 4 per row, re-flowing in place on repeat / hide all agent windows |
| `<leader>ap` | Team status: state, role, current task, pending mail, overrides |
| `<leader>am` | Type a message into an agent's terminal |
| `<leader>ao` / `<leader>aT` | Open / toggle the current agent terminal |
| `<leader>aw…` | Workspaces: `n`ew, `l`oad, `L`ist, `r`emove, `R`ename, `s`ave-as |
| `<leader>aa…` | Agents: `a`dd, `r`emove, `s`top, `R`estart, `f`resh conversation, `d`efine, `c`opy, `e`dit global, `x` delete, `l`ist, `p`ush, `o`verrides, `z` reset |
| `<leader>an…` / `<leader>ad…` / `<leader>as…` | Notes / pinned dirs / system prompt: `a`dd, `e`dit, `v`iew, `d`elete. Each asks which agent when more than one is live, and saves as a workspace override. |
| `<leader>aR` | Edit the picked agent's role for this workspace |
| `<leader>av` / `<leader>ae` | View an agent's context grid / the shared ephemeral context |
| `<leader>at…` / `<leader>ah…` | Tmux captures / history |
| `<leader>ax` (visual) | Send the selection to an agent, prefixed with `path:lines` |
| `<leader>aQ` | Graceful quit |

See `lua/nvim-agent/keymaps.lua` for the full list.

## How context reaches the agent

### Environment variables

When the plugin spawns either the agent CLI (e.g. `claude`) or its MCP server, it injects the following variables into the subprocess environment:

| Var | Agent process | MCP server | Value |
| --- | :---: | :---: | --- |
| `NVIM_AGENT_ACTIVE_DIR` | ✓ | ✓ | `~/.nvim-agent/sessions/<instance-id>/<name>/active/` — this session's mirror of its agent |
| `NVIM_AGENT_PROCESS_DIR` | ✓ | ✓ | `~/.nvim-agent/sessions/<instance-id>/` — shared per-Neovim state |
| `NVIM_AGENT_CWD` | ✓ | ✓ | `vim.fn.getcwd()` at session start |
| `NVIM_AGENT_BASE_DIR` | ✓ | ✓ | The configured `base_dir` (defaults to `~/.nvim-agent`) |
| `NVIM_AGENT_INSTANCE_ID` | ✓ | ✓ | UUID minted once per Neovim process when nvim-agent loads |
| `NVIM_AGENT_RUNTIME_DIR` | ✓ | ✓ | `<cwd>/.nvim-agent/instances/<instance-id>/` — this Neovim instance's peer state (status, messages, triggers) |
| `NVIM_AGENT_HISTORY_DIR` | ✓ | ✓ | `<cwd>/.nvim-agent/workspaces/<workspace>/history/` — the workspace's work-history vault, shared across instances |
| `NVIM_AGENT_NVIM_ADDR` | – | ✓ | `vim.v.servername` — used by the MCP server to RPC into the parent Neovim |

Custom adapters can read these to find the right files (see `lua/nvim-agent/adapter/README.md`).

### The `UserPromptSubmit` hook

The `claude_code` adapter writes a small shell script to `~/.nvim-agent/hooks/claude_code_prompt.sh` and registers it as a `UserPromptSubmit` hook in the per-session `<session.dir>/mcp-settings.json` that Claude Code is launched with via `--mcp-config`.

Claude Code runs the hook before every prompt and prepends the hook's stdout to the user's message as additional context. The script reads files relative to `$NVIM_AGENT_ACTIVE_DIR`, `$NVIM_AGENT_PROCESS_DIR`, `$NVIM_AGENT_CWD`, and `$NVIM_AGENT_RUNTIME_DIR`.

### What the hook injects on each prompt

- **Session-scoped** (from `$NVIM_AGENT_ACTIVE_DIR`, the agent mirror):
  - `role.md` — the agent's role
  - `user_notes.md` — standing user instructions
  - `persistent_dirs.json` — pinned code paths
- **Project root**: `PROJECT.md` (if present) — shared by all agents in the project
- **Process-shared** (from `$NVIM_AGENT_PROCESS_DIR`):
  - `ephemeral.json` — open buffers, cursor, git status, diagnostics, quickfix
  - `tmux_captures.json` — captured tmux pane content (if any)
- **Instance-local** (from `$NVIM_AGENT_RUNTIME_DIR`):
  - Pending messages addressed to this session
  - Status + role summary of all peer agents hosted by the same Neovim
- **Workspace-wide** (from `$NVIM_AGENT_HISTORY_DIR`):
  - Today's entries for this agent from the workspace's work-history vault, and the vault's topic names

Peer state is deliberately keyed by Neovim instance, not by project directory. Two Neovim windows open on the same repo each mint their own instance id at startup and get their own `instances/<instance-id>/` subtree, so their agents never see each other's statuses, mailboxes, history, or wakeup triggers. If `$NVIM_AGENT_RUNTIME_DIR` is missing the hook and MCP tools fail closed rather than falling back to a shared location.

Other adapters can opt into the same flow by emitting a hook script and registering it however the target CLI expects.

## Peer discovery and delegation

Every running agent advertises a status file containing its current task and its role, taken from `role.md`. The hook feeds every peer's role and status to each agent before every prompt, and the `list_agent_roles`, `list_agent_statuses`, `send_message`, `trigger_agent`, and `spawn_agent` MCP tools are how agents coordinate. Because the role is both the agent's own opening instruction and the text peers read, write it as a statement of responsibility: "Owns the test suite. Delegate anything that needs new or changed tests here." See `lua/nvim-agent/mcp/tools.lua` for the full tool surface.

### Work history

Each workspace keeps its agents' work history as an **Obsidian vault** at `<cwd>/.nvim-agent/workspaces/<workspace>/history/`. It persists across Neovim restarts, so days accumulate and topics link work across them, and it is shared by every Neovim instance running that workspace; each entry records which instance wrote it, and `history: "fresh"` only removes the launching instance's own entries. `:NvimAgent history open` (`<leader>aho`) opens its README and prints the folder path to open in Obsidian. Agents write to it only through `log_work(summary, title?, topics?)`: every call creates one note, `agents/<agent>/YYYY-MM-DD/HH-MM-<title>.md`, adds it to that agent's `index.md` under the day's heading, and links it from each `topics/<topic>.md`, so a topic note is a cross-agent, cross-day thread of everything tagged with it. Agents read it back with `read_agent_history`, `read_cwd_history`, `list_history_topics`, and `read_history_topic`. The rules for what to log and how to tag it live in the core preamble, which agents cannot edit; the hook injects today's note and the topic list before every prompt. The `history` key in an agent's `config.json` controls whether its notes persist across launches.

`spawn_agent(name, system_prompt?, role?, user_notes?)` has three behaviours: if `name` is an exited peer it is relaunched; if it is an agent in the library it is added to the workspace and launched; otherwise `system_prompt` and `role` are required and a new agent is saved to the library's spawned section, added, and launched.

## How nvim-agent uses the filesystem

### 1. Global — `~/.nvim-agent/` (per user, persistent)

```
~/.nvim-agent/
├── agents/                            # the global agent library
│   ├── <name>/                        # one dir per agent you defined
│   │   ├── role.md                    # required
│   │   ├── system_prompt.md
│   │   ├── user_notes.md
│   │   ├── persistent_dirs.json
│   │   └── permissions.json           # optional, adapter-specific
│   └── spawned/<name>/                # agents created at runtime via spawn_agent
├── sessions/<instance-id>/            # one dir per running Neovim, keyed by its startup UUID (ephemeral)
│   ├── ephemeral.json                 # editor state, shared by all sessions in this nvim
│   ├── tmux_captures.json             # captured tmux panes, shared
│   └── <session_name>/
│       ├── active/                    # mirror of the agent's files for this session
│       └── mcp-settings.json          # adapter-specific MCP wiring
└── hooks/                             # adapter hook scripts
    └── claude_code_prompt.sh
```

`sessions/<instance-id>/` dies with the Neovim process. Everything else persists.

### 2. Project-local — `<cwd>/.nvim-agent/` (gitignored)

```
<cwd>/.nvim-agent/
├── workspaces/<name>/workspace.json   # { "name", "agents": [{ "name", "agent", "conversation" }] }, saved on every change
├── workspaces/<name>/<session>/       # that member's override files for this workspace only
│   ├── user_notes.md                  #   any of the agent's files may appear here;
│   └── persistent_dirs.json           #   present = used instead of the global one
├── workspaces/<name>/history/         # the workspace's work-history vault (open in Obsidian)
│   ├── agents/<agent>/index.md        #   that agent's entries grouped by day
│   ├── agents/<agent>/YYYY-MM-DD/     #   subdir per day …
│   │   └── HH-MM-<title>.md           #   … one note per log_work call
│   └── topics/<topic>.md              #   per-topic links across agents and days
├── workspaces/ephemeral/workspace.json
└── instances/<instance-id>/           # one subtree per running Neovim (UUID minted at setup)
    ├── status/<agent>.json            # peer discovery: each running agent advertises here
    ├── messages/<agent>.md            # mailboxes for inter-agent send_message()
    └── triggers/<agent>.md            # wakeup signals
```

**Add `.nvim-agent/` to your project's `.gitignore`.** Workspaces reference agents from your personal library, so they are not meaningful to share. Instance subtrees are not deleted on exit; `:NvimAgent history project` stitches history from every instance back together for you, while agents themselves only ever see their own instance.

## Custom adapters

To wire up a different agent CLI, implement an adapter that inherits from `require("nvim-agent.adapter").base`. See `lua/nvim-agent/adapter/README.md` for the full interface and a worked example based on the bundled Claude Code adapter.

## License

Apache 2.0 — see `LICENSE`.
