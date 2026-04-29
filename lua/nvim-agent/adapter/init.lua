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

function M.base:get_system_prompt()
	return require("nvim-agent.context").get_agent_preamble()
end

function M.base:get_context_injection_config()
	return nil
end

--- Return the permission profile for a given agent.
--- Adapters override this to provide agent-specific permissions.
--- @param agent_name string
--- @param cwd string|nil
--- @return table  { allow: string[], deny: string[] }
function M.base:get_agent_permissions(agent_name, cwd)
	-- Default: full permissions for backward compatibility
	return {
		allow = { "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)", "mcp__nvim-agent__*" },
		deny = {},
	}
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
