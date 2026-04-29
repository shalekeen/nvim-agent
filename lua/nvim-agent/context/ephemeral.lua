local M = {}

local function safe_system(cmd)
    local ok, result = pcall(vim.fn.system, cmd)
    if ok and vim.v.shell_error == 0 then
        return vim.trim(result)
    end
    return nil
end

local function get_open_buffers()
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
                })
            end
        end
    end
    return bufs
end

local function get_cursor_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" or vim.bo[bufnr].buftype ~= "" then
        return nil
    end
    local pos = vim.api.nvim_win_get_cursor(0)
    return {
        file = name,
        line = pos[1],
        col = pos[2],
    }
end

local function get_git_info()
    local branch = safe_system("git rev-parse --abbrev-ref HEAD 2>/dev/null")
    if not branch then
        return nil
    end
    local status = safe_system("git status --porcelain 2>/dev/null")
    local log_raw = safe_system("git log --oneline -5 2>/dev/null")
    local commits = {}
    if log_raw then
        for line in log_raw:gmatch("[^\n]+") do
            table.insert(commits, line)
        end
    end
    return {
        branch = branch,
        status = status or "",
        recent_commits = commits,
    }
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

function M.gather()
    return {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        cwd = vim.fn.getcwd(),
        open_buffers = get_open_buffers(),
        cursor = get_cursor_context(),
        git = get_git_info(),
        recent_diagnostics = get_recent_diagnostics(),
        quickfix = get_quickfix_entries(),
    }
end

return M
