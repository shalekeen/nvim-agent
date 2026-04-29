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

function M.get_agent_preamble()
    local cfg = config.get()
    local prompt = cfg.default_system_prompt or ""
    if prompt ~= "" then
        return prompt .. "\n\n" .. cfg.agent_instruction_header
    end
    return cfg.agent_instruction_header
end

return M
