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

--- Write all context files for a session.
--- Ephemeral is written to process_dir (shared by all sessions in the same Neovim process).
--- Session-specific flavor files are seeded into active_dir only if missing.
--- @param active_dir string      Session's active directory (flavor files live here)
--- @param process_dir string|nil Process-level shared dir (ephemeral.json lives here)
function M.write_all(active_dir, process_dir)
    if not active_dir then return end
    local cfg = config.get()

    -- Ephemeral is shared per-process; falls back to active_dir if no process_dir given
    local eph_target = process_dir or active_dir
    local eph = ephemeral.gather()
    write_file(eph_target .. "/" .. cfg.context_files.ephemeral, vim.json.encode(eph))

    -- Ensure session-specific files exist in active_dir.
    -- Do NOT overwrite — they hold session-specific flavor content.
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

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- Build the three-layer system prompt for a session, in order:
---
---   1. config.nvim_agent_preamble  -- the runtime contract from
---      nvim-agent itself (always present; not affected by user edits to
---      flavor files).
---   2. <active_dir>/system_prompt.md    -- the user-editable flavor prompt.
---      Falls back to config.default_system_prompt when the file is empty
---      or missing.
---   3. <active_dir>/agent_prompt.md     -- the user-editable per-agent
---      addendum. OPTIONAL — omitted entirely when the file is empty or
---      missing.
---
--- Layers are joined by a blank line. Empty layers are dropped so we don't
--- emit consecutive blank-line gaps.
---
--- @param active_dir string|nil  Session active dir; nil → use config defaults
---                               only (no system_prompt.md/agent_prompt.md read).
--- @return string
function M.compose_system_prompt(active_dir)
    local cfg = config.get()
    local parts = {}

    if cfg.nvim_agent_preamble and cfg.nvim_agent_preamble ~= "" then
        table.insert(parts, cfg.nvim_agent_preamble)
    end

    local sys = active_dir and read_file(active_dir .. "/system_prompt.md")
    if not sys or sys == "" then
        sys = cfg.default_system_prompt or ""
    end
    if sys ~= "" then
        table.insert(parts, sys)
    end

    if active_dir then
        local agent = read_file(active_dir .. "/agent_prompt.md")
        if agent and agent ~= "" then
            table.insert(parts, agent)
        end
    end

    return table.concat(parts, "\n\n")
end

return M
