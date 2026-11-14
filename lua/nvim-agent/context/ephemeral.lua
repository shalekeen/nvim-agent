-- Ephemeral editor state: what only Neovim knows. Open file buffers, the
-- file and cursor the user was last working in, diagnostics, quickfix.
-- Nothing here shells out: the snapshot is a handful of API reads. Anything
-- an agent can discover itself (git, the filesystem) is deliberately absent.
--
-- The snapshot is written when the user enters or leaves a FILE buffer, so
-- it describes their editing and never the agent terminals themselves.
local M = {}

-- Last file buffer the user was in, and the cursor there. Recorded by the
-- autocmds on BufEnter/BufLeave of file buffers so the snapshot still knows
-- "where the user was" after they switch into an agent terminal.
M.last_file = nil

--- Record the user's position in a file buffer. No-op for non-file buffers.
--- @param bufnr integer
--- @param win integer|nil  window showing it (defaults to the current window)
--- @return boolean recorded
function M.note_file_buffer(bufnr, win)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
        return false
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return false
    end
    win = win or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
        return false
    end
    local pos = vim.api.nvim_win_get_cursor(win)
    M.last_file = { bufnr = bufnr, file = name, line = pos[1], col = pos[2] }
    return true
end

local function get_open_buffers(active_bufnr)
    local bufs = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            local bt = vim.bo[bufnr].buftype
            if name ~= "" and bt == "" then
                table.insert(bufs, {
                    path = name,
                    modified = vim.bo[bufnr].modified,
                    filetype = vim.bo[bufnr].filetype,
                    active = bufnr == active_bufnr or nil,
                })
            end
        end
    end
    return bufs
end

--- The file and cursor the user is (or was last) working in: the current
--- buffer when it is a file, otherwise the last file buffer recorded.
local function get_cursor_context()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= "" then
        local pos = vim.api.nvim_win_get_cursor(0)
        return { bufnr = bufnr, file = vim.api.nvim_buf_get_name(bufnr), line = pos[1], col = pos[2] }
    end
    local last = M.last_file
    if last and vim.api.nvim_buf_is_valid(last.bufnr) and vim.api.nvim_buf_is_loaded(last.bufnr) then
        return last
    end
    return nil
end

local function get_recent_diagnostics()
    local diags = {}
    local all = vim.diagnostic.get()
    local severity_names = { "Error", "Warn", "Info", "Hint" }
    local count = 0
    for _, d in ipairs(all) do
        if count >= 50 then
            break
        end
        local bufname = vim.api.nvim_buf_get_name(d.bufnr or 0)
        table.insert(diags, {
            file = bufname,
            line = d.lnum + 1,
            severity = severity_names[d.severity] or "Unknown",
            message = d.message,
        })
        count = count + 1
    end
    return diags
end

local function get_quickfix_entries()
    local qf = vim.fn.getqflist()
    local entries = {}
    local count = 0
    for _, item in ipairs(qf) do
        if count >= 20 then
            break
        end
        local bufname = ""
        if item.bufnr and item.bufnr > 0 then
            bufname = vim.api.nvim_buf_get_name(item.bufnr)
        end
        table.insert(entries, {
            file = bufname,
            line = item.lnum,
            col = item.col,
            text = item.text,
            type = item.type,
        })
        count = count + 1
    end
    return entries
end

--- Snapshot of editor state. Pure API reads; never blocks.
function M.gather()
    local cursor = get_cursor_context()
    return {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        cwd = vim.fn.getcwd(),
        open_buffers = get_open_buffers(cursor and cursor.bufnr),
        cursor = cursor and { file = cursor.file, line = cursor.line, col = cursor.col } or nil,
        recent_diagnostics = get_recent_diagnostics(),
        quickfix = get_quickfix_entries(),
    }
end

return M
