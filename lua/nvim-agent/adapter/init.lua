local M = {}

local builtin_adapters = {
	claude_code = "nvim-agent.adapter.claude_code",
}

local active_adapter = nil

-- Base adapter prototype. Concrete adapters inherit via metatable.
M.base = {}

function M.base:get_cmd()
	error("nvim-agent: adapter must implement get_cmd()")
end

function M.base:setup()
	-- no-op by default
end

--- Return the permission profile for a session's agent.
---
--- The base grants NOTHING. Permission strings are inherently CLI-specific
--- (Claude Code spells them "Bash(*)" / "mcp__nvim-agent__*"; other CLIs
--- have their own grammar or no per-tool model at all), so a neutral
--- default is the empty profile. Adapters whose CLI has a permission model
--- override this and read <session.active_dir>/permissions.json — the
--- agent's optional permissions file, mirrored into the session at launch.
--- See claude_code.lua for a profile-based implementation.
--- @param session table
--- @return table  { allow: string[], deny: string[] }
function M.base:get_agent_permissions(session)
	return { allow = {}, deny = {} }
end

--- Return the "how context reaches you" section of the system prompt
--- (layer 1b, inserted right after config.nvim_agent_preamble).
---
--- The core preamble is CLI-neutral: it lists the context files nvim-agent
--- maintains and the MCP tool catalogue, but says nothing about HOW those
--- files get in front of the agent, because that depends on the CLI
--- (pre-prompt hook, stdin shim, or nothing at all). This method is where
--- the adapter states that contract, in its own CLI's vocabulary.
---
--- The base default assumes a CLI with no pre-prompt injection and tells
--- the agent to read the files on demand. Adapters with a hook override it.
--- Return "" to contribute nothing.
--- @return string
function M.base:get_context_contract()
	return [[## How context reaches you

This CLI has no automatic pre-prompt injection configured, so the context files listed
above are NOT in your prompt by default. Read them on demand with the read_file MCP tool
using the directory paths above whenever you need fresh editor state (ephemeral.json),
peer messages (messages/<your name>.md under the runtime dir), or your own history.
Use the MCP tools for file reads and edits so changes land in the user's live Neovim
buffers rather than bypassing the editor.]]
end

--- Extra environment variables for the CLI process itself (merged into the
--- terminal's `termopen` env after the harness's NVIM_AGENT_* variables, which
--- cannot be overridden). Use it for CLI-specific knobs that only make sense
--- when the CLI runs inside a Neovim terminal split.
--- @param session table
--- @return table<string, string>
function M.base:get_env(session)
	return {}
end

--- Name the CLI's conversation for this session. The harness calls it with
--- "<session name> <YYYY-MM-DD HH:MM>" right before each launch (initial and
--- relaunch alike), after recording the title in `session.conversation_title`
--- so `get_cmd` can pass it as a flag. It may also be called on a running
--- session (a user-driven rename): adapters whose CLI accepts a rename
--- command at runtime send it to the terminal then. Base does nothing;
--- return true if the CLI was told the name.
--- @param session table
--- @param title string
--- @return boolean
function M.base:rename_conversation(session, title)
	return false
end

--- Resume the CLI conversation named `title` at this session's next launch,
--- instead of starting a new one. The harness calls it before `get_cmd` with
--- the title it recorded for this member in the workspace manifest. Return
--- true only if the CLI has that conversation and will reopen it; set
--- `session.resume_conversation = true` and `session.conversation_title`
--- so `get_cmd` can emit the right flags. On false the harness mints a new
--- title, calls `rename_conversation`, and records that instead. Base: the
--- CLI cannot resume, so every launch is a new conversation.
--- @param session table
--- @param title string
--- @return boolean
function M.base:resume_conversation(session, title)
	return false
end

function M.base:on_enter(bufnr)
	-- no-op by default; adapters can override to run code when entering the agent buffer
end

--- Create a new adapter inheriting from base.
--- @param overrides table Method overrides
--- @return table
function M.new(overrides)
	local adapter = setmetatable({}, { __index = M.base })
	for k, v in pairs(overrides or {}) do
		adapter[k] = v
	end
	return adapter
end

--- Resolve an adapter from a string name or table.
--- @param spec string|table
--- @return table
function M.resolve(spec)
	if type(spec) == "table" then
		return setmetatable(spec, { __index = M.base })
	end

	if type(spec) == "string" then
		local mod_path = builtin_adapters[spec]
		if not mod_path then
			error(
				"nvim-agent: unknown adapter '"
					.. spec
					.. "'. Available: "
					.. table.concat(vim.tbl_keys(builtin_adapters), ", ")
			)
		end
		return require(mod_path) --[[@as table]]
	end

	error("nvim-agent: adapter must be a string name or adapter table")
end

function M.set_active(adapter)
	active_adapter = adapter
end

--- @return table|nil
function M.get_active()
	return active_adapter
end

return M
