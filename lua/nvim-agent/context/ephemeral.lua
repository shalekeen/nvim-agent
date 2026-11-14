local M = {}

-- Git state is gathered ASYNCHRONOUSLY and cached. gather() is called on
-- every BufEnter of an agent terminal (and at launch); shelling out to git
-- there used to block Neovim for the duration of three `git` invocations,
-- which on a large or recently-touched repository (index refresh) can be
-- seconds — felt as a hang when switching between agent windows. Now the
-- snapshot uses the last known git state, and a background refresh rewrites
-- the context file when it lands.
M.GIT_TTL_MS = 2000
M._git = { info = nil, at = 0, inflight = false, cwd = nil }

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

-- One shell invocation; sections separated by NUL. An empty first section
-- means "not a git repository".
local GIT_PROBE = "git rev-parse --abbrev-ref HEAD 2>/dev/null; printf '\\0'; git status --porcelain 2>/dev/null; printf '\\0'; git log --oneline -5 2>/dev/null"

local function parse_git_probe(out)
    local parts = vim.split(out or "", "\0", { plain = true })
    local branch = vim.trim(parts[1] or "")
    if branch == "" then
        return nil
    end
    local commits = {}
    for line in (parts[3] or ""):gmatch("[^\n]+") do
        table.insert(commits, line)
    end
    return {
        branch = branch,
        status = vim.trim(parts[2] or ""),
        recent_commits = commits,
    }
end

--- Refresh the cached git state in the background. `on_done(changed)` runs
--- on the main loop when the probe finishes (changed = the cache was
--- updated). A refresh is skipped while one is in flight or the cache is
--- younger than GIT_TTL_MS for the same cwd.
--- @param cwd string
--- @param on_done fun(changed: boolean)|nil
function M.refresh_git(cwd, on_done)
    local g = M._git
    local now = (vim.uv or vim.loop).now()
    if g.inflight or (g.cwd == cwd and now - g.at < M.GIT_TTL_MS) then
        if on_done then
            on_done(false)
        end
        return
    end
    if not vim.system then
        -- Neovim < 0.10: no async process API; leave git out rather than block.
        if on_done then
            on_done(false)
        end
        return
    end
    g.inflight = true
    local ok = pcall(vim.system, { "sh", "-c", GIT_PROBE }, { cwd = cwd, text = true, timeout = 10000 }, function(res)
        vim.schedule(function()
            g.inflight = false
            g.at = (vim.uv or vim.loop).now()
            g.cwd = cwd
            g.info = res.code == 0 and parse_git_probe(res.stdout) or nil
            if on_done then
                on_done(true)
            end
        end)
    end)
    if not ok then
        g.inflight = false
        if on_done then
            on_done(false)
        end
    end
end

local function get_git_info(cwd)
    local g = M._git
    if g.cwd == cwd then
        return g.info
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

--- Snapshot of editor state. Never blocks: git comes from the cache (nil
--- until the first background probe lands); call refresh_git() to update it.
function M.gather()
    local cwd = vim.fn.getcwd()
    return {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        cwd = cwd,
        open_buffers = get_open_buffers(),
        cursor = get_cursor_context(),
        git = get_git_info(cwd),
        recent_diagnostics = get_recent_diagnostics(),
        quickfix = get_quickfix_entries(),
    }
end

return M
