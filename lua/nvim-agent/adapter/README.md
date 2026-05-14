# nvim-agent Adapter Interface

An **adapter** is a Lua module that bridges nvim-agent and a specific
coding-agent CLI (Claude Code, Cursor CLI, Aider, Codex, etc.). The harness
handles sessions, terminal management, context-file plumbing, and the MCP
server; the adapter handles "how do I actually launch *this* CLI and wire
context into it?"

This document is the porting guide. If you're adding support for a new CLI,
read this top-to-bottom — it's deliberately self-contained.

For a working reference, see [`claude_code.lua`](./claude_code.lua). For a
fork-and-fill starting point, see [`TEMPLATE.lua`](./TEMPLATE.lua).

---

## 1. The contract: what the harness expects

The rest of nvim-agent invokes adapter methods at well-defined lifecycle
points. Implement the ones whose lifecycle hook you need.

| Method | When called | Required? | Purpose |
|---|---|:-:|---|
| `get_cmd(session)` | When a session's terminal is opened (`terminal.open`) | ✅ | Return the argv array to pass to `termopen`. Must succeed even when called with a nil session (defensive default). |
| `setup()` | Once at plugin startup (from `nvim-agent.setup`) | ❌ | Global one-time install: write hook scripts, register MCP server in CLI's config, install permissions, write CLI-side instruction file. Must be **idempotent** — runs on every Neovim startup. |
| `setup_session_mcp(session)` | Before each session's `termopen` (from `terminal.open`) | ❌ | Write per-session config the CLI reads at launch (typically MCP server pointer + injection hook). Fresh every session, no idempotency required. |
| `setup_project_permissions(cwd)` | When a workspace is launched (`commands.lua`, `init.lua`) | ❌ | Write per-project CLI config so agents in that project don't get hammered with permission prompts. Idempotent. |
| `setup_buffer_keymaps(bufnr)` | Once per session terminal buffer (from `terminal.open`) | ❌ | Add buffer-local keymaps for the terminal (e.g. `<Esc><Esc>` to leave terminal mode). |
| `on_enter(bufnr)` | Every `BufEnter` of a session terminal (from `autocmds.lua`) | ❌ | Sync state / refresh ephemeral context when the user looks at the buffer. The harness already refreshes `ephemeral.json` here, so most adapters can skip this. |

Only `get_cmd(session)` is mandatory. Everything else is optional and
checked with `if adapter.<method> then` before being called, so leaving
something off is safe.

A few methods exist on the base prototype but are **not** called by the
harness — they're adapter-private helpers that you can override if your
implementation wants them. `get_agent_permissions(name, cwd)` and
`get_system_prompt()` fall in this bucket. Don't feel obligated to
implement them.

---

## 2. The session object

`get_cmd(session)`, `setup_session_mcp(session)`, etc. all receive the
same session table. Fields you can rely on:

| Field | Type | Description |
|---|---|---|
| `session.id` | `string` | Compound ID `"<pid>_<name>"`. Unique across all running Neovims. |
| `session.name` | `string` | User-facing name. `"main"` for the first session, user-supplied for subsequent ones. |
| `session.instance_num` | `number` | Sequential 1-indexed creation order. Used for buffer naming. |
| `session.window_id` | `number` | Owning Neovim's PID. |
| `session.process_dir` | `string` | `~/.nvim-agent/sessions/<pid>/`. Shared by all sessions in this Neovim. Holds `ephemeral.json`. |
| `session.dir` | `string` | `<process_dir>/<name>/`. Per-session root. Good place for `mcp-settings.json` and any other per-session config. |
| `session.active_dir` | `string` | `<dir>/active/`. Holds the session's context files (`system_prompt.md`, `user_notes.md`, `role.md`, `.flavor_meta.json`, etc.). **This is the path you point your CLI at.** |
| `session.flavor` | `string` | The flavor name this session was launched with. |
| `session.checkpoint` | `string\|nil` | Optional checkpoint name within the flavor. |
| `session.bufnr` | `number\|nil` | Terminal buffer number (nil before terminal open). |
| `session.jobid` | `number\|nil` | termopen job ID (nil before launch). |

---

## 3. Composing the system prompt

The system prompt is built in three layers via
`nvim-agent.context.compose_system_prompt(active_dir)`:

1. **Preamble** (`config.nvim_agent_preamble`) — the runtime contract that
   tells the agent how to interpret editor context. Always included.
   Authored once by nvim-agent itself; users don't edit it.
2. **`<active_dir>/system_prompt.md`** — the user-editable flavor base.
   Falls back to `config.default_system_prompt` if empty/missing.
3. **`<active_dir>/agent_prompt.md`** — optional per-agent addendum. Skipped
   if empty/missing.

Layers are joined with blank lines. **Always go through
`compose_system_prompt(active_dir)`** rather than reading `system_prompt.md`
directly — otherwise you skip the preamble and the agent won't know how to
read the per-prompt context the hook injects.

```lua
function M:get_cmd(session)
    local prompt = require("nvim-agent.context").compose_system_prompt(session.active_dir)
    return { "your-cli", "--system-prompt", prompt }
end
```

If your CLI doesn't accept a system prompt via argv (e.g. it only reads from
a file), write `prompt` to a temp path and pass that path instead. See
claude_code.lua for the argv-string path; an Aider-style adapter would
write to a file inside `session.dir`.

---

## 4. Per-prompt context injection

The system prompt is set **once at process launch**. The dynamic editor
context (current cursor, open buffers, peer agent statuses, message
mailbox, etc.) is injected **before every user prompt** via a hook script
that runs in the CLI's pre-prompt lifecycle.

Whether your CLI supports this depends on the CLI:

| CLI feature | What you do |
|---|---|
| Pre-prompt hooks (Claude Code) | Write a hook script that `cat`s context files; register it in the CLI's per-session settings. The CLI runs it before each prompt. |
| No pre-prompt hooks (most CLIs) | Either (a) skip per-prompt context entirely and rely on the agent calling MCP tools when it needs editor state, or (b) wrap the CLI in a stdin-injecting shim. |

The harness writes context files to `session.active_dir` and refreshes
`ephemeral.json` automatically on every `BufEnter` of an agent terminal.
You don't have to read these files yourself — the hook script (or the
agent via MCP tools) does.

### Files the harness writes to `session.active_dir`

| File | Volatility | Description |
|---|---|---|
| `system_prompt.md` | Stable | Flavor base, edited by user occasionally. |
| `agent_prompt.md` | Stable | Optional per-agent addendum. |
| `user_notes.md` | Stable | Standing user-facing notes. |
| `persistent_dirs.json` | Stable | Pinned code paths the user wants the agent to know about. |
| `role.md` | Stable | Agent role (used for peer discovery in workspaces). |
| `.flavor_meta.json` | Stable | Which flavor/checkpoint this session loaded from. |

### Files in `session.process_dir` (shared across all sessions in this Neovim)

| File | Volatility | Description |
|---|---|---|
| `ephemeral.json` | High | Refreshed on every `BufEnter`: cursor, open buffers, recent diagnostics, git status. |
| `tmux_captures.json` | Low | Tmux pane snapshots, manually captured. |

### Files in `<cwd>/.nvim-agent/` (project-local, shared with peer agents)

| File | Description |
|---|---|
| `status/<agent>.json` | Each agent's current task — updated via `update_status` MCP tool. |
| `messages/<agent>.md` | Agent's inbound message queue. |
| `history/<agent>.md` | Persistent work log written via `log_work`. |

For the canonical, prefix-cache-friendly ordering of these files in the
hook script, see `hook_script_content()` in `claude_code.lua` — stable
content first, volatile content last, so Anthropic's prompt cache can
reuse the longest possible prefix between prompts.

---

## 5. MCP server integration (optional but recommended)

The nvim-agent MCP server lets the agent reach back into Neovim:
read/write buffers, search files, execute ex commands, send messages to
peer agents, log work, etc. It runs as a subprocess of the CLI when the
CLI supports MCP.

If your CLI **supports MCP** (Claude Code does):

1. In `setup_session_mcp(session)`, write a settings file that points to
   the server at `<plugin>/lua/nvim-agent/mcp/server.lua`.
2. Spawn it via `vim.v.progpath` (current Neovim binary) with `-l <path>`
   so users don't need an external Lua/LuaJIT.
3. Set these env vars on the spawned process:
   - `NVIM_AGENT_NVIM_ADDR = vim.v.servername` (the parent Neovim's RPC
     socket — **not** `NVIM_LISTEN_ADDRESS`, that one is intercepted by
     `nvim -l`)
   - `NVIM_AGENT_ACTIVE_DIR = session.active_dir` (so the MCP server
     serves files from the right session)
   - `NVIM_AGENT_PROCESS_DIR = session.process_dir` (for ephemeral.json)
   - `NVIM_AGENT_CWD = vim.fn.getcwd()` (for project-local state)

Example settings shape (Claude Code format):

```lua
{
    mcpServers = {
        ["nvim-agent"] = {
            command = vim.v.progpath,
            args = { "-l", mcp_server_path },
            env = {
                NVIM_AGENT_NVIM_ADDR = vim.v.servername,
                NVIM_AGENT_ACTIVE_DIR = session.active_dir,
                NVIM_AGENT_PROCESS_DIR = session.process_dir,
                NVIM_AGENT_CWD = vim.fn.getcwd(),
            },
        },
    },
    -- Per-prompt context injection hook (CLI-specific shape):
    hooks = {
        UserPromptSubmit = {
            { hooks = { { type = "command", command = hook_script_path } } },
        },
    },
    -- Pre-allow MCP tools so the agent isn't prompted for each one:
    permissions = { allow = { "mcp__nvim-agent__*" } },
}
```

If your CLI **does NOT support MCP**, the agent can still function — it
just won't be able to call Neovim from the inside. The user-facing context
files still work. Document this clearly in the adapter so users know what
they're giving up.

---

## 6. Permissions

Most CLIs ask the user before running tools. For an agentic workflow this
is fatal — the user gets prompted for every `read_file`, every `Bash`,
every edit. Adapters should pre-grant the tools the agent legitimately
needs.

**Per-session permissions** flow through `setup_session_mcp(session)`. Most
CLIs have a settings.json-style file you can write to that allows or
denies specific tools.

**Per-agent permissions** are an nvim-agent convention: an agent's
definition dir may contain `permissions.json`. The format the bundled
adapter uses:

```json
{ "profile": "qa" }
```

or

```json
{ "allow": ["mcp__nvim-agent__read_file"], "deny": ["Bash(*)"] }
```

`claude_code.lua` defines named profiles (`full`, `qa`, `oversight`,
`orchestrator`) and a `get_agent_permissions(name, cwd)` helper that
resolves them. If you want the same UX in your adapter, copy the pattern.
If your CLI's permission model is simpler, do something simpler.

**Per-project permissions** flow through `setup_project_permissions(cwd)`.
Use this to write the CLI's project-scoped settings file (Claude Code:
`<cwd>/.claude/settings.json`) so the agent doesn't get permission
prompts every time it touches a file inside the project.

---

## 7. Registering your adapter

Open `lua/nvim-agent/adapter/init.lua` and add an entry to
`builtin_adapters`:

```lua
local builtin_adapters = {
    claude_code = "nvim-agent.adapter.claude_code",
    your_cli = "nvim-agent.adapter.your_cli",  -- NEW
}
```

Users then select it via plugin config:

```lua
require("nvim-agent").setup({ adapter = "your_cli" })
```

Out-of-tree adapters are also supported — pass the adapter table directly
instead of a string name:

```lua
require("nvim-agent").setup({ adapter = require("my-plugin.my-adapter") })
```

`adapter.resolve()` wraps the table in the base metatable automatically,
so out-of-tree adapters get the same defaults as bundled ones.

---

## 8. Porting checklist

Copy `TEMPLATE.lua` to `<your_cli>.lua` and work through this:

- [ ] CLI is installed and on `$PATH` — `setup()` calls `vim.fn.system("which <cli>")` and warns if missing
- [ ] `get_cmd(session)` builds the right argv array
  - [ ] Calls `compose_system_prompt(session.active_dir)` to assemble the prompt (or writes it to a file)
  - [ ] Points at `session.dir/mcp-settings.json` (or your CLI's equivalent) if MCP-capable
  - [ ] Nil-guards `session` and returns a safe default
- [ ] `setup_session_mcp(session)` writes per-session config (if MCP-capable)
  - [ ] MCP server entry uses `vim.v.progpath -l <server.lua>`
  - [ ] Env vars include `NVIM_AGENT_NVIM_ADDR`, `NVIM_AGENT_ACTIVE_DIR`, `NVIM_AGENT_PROCESS_DIR`, `NVIM_AGENT_CWD`
  - [ ] Pre-allows `mcp__nvim-agent__*` so the agent doesn't get prompted per-tool
  - [ ] Registers the pre-prompt hook (if your CLI supports them)
- [ ] `setup()` is idempotent — writing the same settings twice doesn't corrupt them
  - [ ] Hook script is written to `~/.nvim-agent/hooks/<adapter>_prompt.sh`
  - [ ] Global CLI settings.json updated to include nvim-agent without clobbering other entries
- [ ] `setup_project_permissions(cwd)` writes project-scoped settings (if applicable)
- [ ] Registered in `builtin_adapters` in `adapter/init.lua`
- [ ] Smoke-tested: `:NvimAgent session new` launches the CLI, MCP tools work, peer messaging works

---

## 9. Testing your adapter

The plugin doesn't ship adapter-specific test infrastructure (since each
CLI has its own setup-validation needs). Smoke-test by hand:

```vim
" Configure the plugin to use your adapter
:lua require("nvim-agent").setup({ adapter = "your_cli" })

" Launch a session and confirm the CLI starts cleanly
:NvimAgent session new

" In a separate shell, verify the per-session settings were written:
:!cat ~/.nvim-agent/sessions/$NEOVIM_PID/main/mcp-settings.json
```

If your adapter writes hook scripts or CLI settings, add unit tests that
exercise the write paths against a temp `base_dir` (see
`tests/integration_test.lua` for the bootstrap pattern). The existing test
harness already stubs out `which-key` and `barbar`, so adapter logic can
run headless under `nvim -l tests/<your_test>.lua`.

For Claude Code specifically, there's no test file — most of its setup
talks to the host filesystem (`~/.claude/settings.json`), which is hard to
sandbox. If your adapter does the same, prioritize manual smoke testing
over unit testing.

---

## 10. File structure

```
nvim-agent/
├── adapter/
│   ├── init.lua             # Base prototype, resolution, active-adapter registry
│   ├── claude_code.lua      # Reference implementation
│   ├── TEMPLATE.lua         # Fork-and-fill starting point for new adapters
│   └── README.md            # This file
├── agent.lua                # Agent definitions and templates
├── workspace.lua            # Workspace runtime/def dirs and manifest CRUD
├── session.lua              # Per-Neovim session registry
├── terminal.lua             # Calls get_cmd, setup_session_mcp, setup_buffer_keymaps
├── autocmds.lua             # Calls on_enter on BufEnter
├── commands.lua             # Calls setup_project_permissions on workspace launch
├── context/init.lua         # compose_system_prompt — three-layer composition
├── flavor/                  # Flavor library and last-used-flavor persistence
└── mcp/
    ├── server.lua           # JSON-RPC 2.0 over stdio; spawned by the CLI
    ├── tools.lua            # MCP tool implementations
    ├── nvim_rpc.lua         # Shell-based Neovim RPC wrapper
    └── filelock.lua         # mkdir-based cross-process locking
```

---

## TL;DR

The minimum viable adapter:

```lua
local adapter_base = require("nvim-agent.adapter")
local context = require("nvim-agent.context")

local M = adapter_base.new()

function M:get_cmd(session)
    if not session then
        return { "your-cli" }  -- safe default
    end
    local prompt = context.compose_system_prompt(session.active_dir)
    return { "your-cli", "--system-prompt", prompt }
end

return M
```

That gets you a launching session with the right system prompt. Everything
else (MCP, permissions, per-prompt injection) is incremental polish.
