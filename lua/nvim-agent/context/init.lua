local M = {}

local config = require("nvim-agent.config")
local ephemeral = require("nvim-agent.context.ephemeral")

local function write_file(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Write all context files for a session.
--- Ephemeral is written to process_dir (shared by every session in this
--- Neovim instance). Agent files in active_dir are only seeded if missing —
--- they mirror the agent definition and must not be overwritten here.
--- @param active_dir string
--- @param process_dir string|nil
function M.write_all(active_dir, process_dir)
	if not active_dir then
		return
	end
	local cfg = config.get()

	local eph_target = process_dir or active_dir
	local eph = ephemeral.gather()
	write_file(eph_target .. "/" .. cfg.context_files.ephemeral, vim.json.encode(eph))

	local fallbacks = {
		{ cfg.context_files.persistent_dirs, "[]" },
		{
			cfg.context_files.user_notes,
			"# User Notes\n\nAdd behavioral notes here that you want the coding agent to respect.\n",
		},
		{ cfg.context_files.system_prompt, "" },
	}
	for _, entry in ipairs(fallbacks) do
		local path = active_dir .. "/" .. entry[1]
		if vim.fn.filereadable(path) ~= 1 then
			write_file(path, entry[2])
		end
	end
end

--- Build the layered system prompt for a session, in order:
---
---   1.  config.nvim_agent_preamble      -- CLI-neutral runtime contract from
---       nvim-agent (always present).
---   1b. adapter:get_context_contract()  -- the active adapter's statement of
---       HOW context reaches the agent under this CLI. Omitted when no
---       adapter is active or it returns "".
---   2.  <active_dir>/role.md            -- the agent's role, rendered under a
---       "# Your role" heading. Mandatory for every agent; it both steers the
---       agent and is what peers see when deciding whom to delegate to.
---   3.  <active_dir>/system_prompt.md   -- the agent's behaviour prompt.
---       Falls back to config.default_system_prompt when empty or missing.
---
--- Layers are joined by a blank line. Empty layers are dropped.
--- @param active_dir string|nil  nil → config defaults only
--- @return string
function M.compose_system_prompt(active_dir)
	local cfg = config.get()
	local parts = {}

	if cfg.nvim_agent_preamble and cfg.nvim_agent_preamble ~= "" then
		table.insert(parts, cfg.nvim_agent_preamble)
	end

	local adapter = require("nvim-agent.adapter").get_active()
	if adapter and adapter.get_context_contract then
		local contract = adapter:get_context_contract()
		if type(contract) == "string" and contract ~= "" then
			table.insert(parts, contract)
		end
	end

	if active_dir then
		local role = read_file(active_dir .. "/role.md")
		if role and not role:match("^%s*$") then
			table.insert(parts, "# Your role\n\n" .. role:gsub("%s+$", ""))
		end
	end

	local sys = active_dir and read_file(active_dir .. "/system_prompt.md")
	if not sys or sys == "" then
		sys = cfg.default_system_prompt or ""
	end
	if sys ~= "" then
		table.insert(parts, sys)
	end

	return table.concat(parts, "\n\n")
end

return M
