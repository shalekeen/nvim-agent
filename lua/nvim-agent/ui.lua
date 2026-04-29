local M = {}

--- Create a centered floating window
--- @param opts table Options for the floating window
--- @return number bufnr, number winid
local function create_float(opts)
    opts = opts or {}
    local width = opts.width or math.floor(vim.o.columns * 0.8)
    local height = opts.height or math.floor(vim.o.lines * 0.8)

    -- Calculate position to center the window
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create buffer
    local bufnr = vim.api.nvim_create_buf(false, true)

    -- Set buffer options
    vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')

    -- Window options
    local win_opts = {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = opts.border or 'rounded',
        title = opts.title,
        title_pos = 'center',
    }

    -- Create window
    local winid = vim.api.nvim_open_win(bufnr, true, win_opts)

    -- Set window options
    vim.api.nvim_win_set_option(winid, 'winblend', opts.winblend or 0)
    vim.api.nvim_win_set_option(winid, 'cursorline', true)

    return bufnr, winid
end

--- Floating window input
--- @param opts table vim.ui.input options plus optional float options
--- @param on_confirm function Callback when input is confirmed
function M.input(opts, on_confirm)
    opts = opts or {}

    -- Create small floating window for input
    local width = opts.width or 60
    local height = 3
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(bufnr, 'buftype', 'prompt')

    local prompt_text = opts.prompt or 'Input: '
    vim.fn.prompt_setprompt(bufnr, prompt_text)

    -- Set default text if provided
    if opts.default then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {opts.default})
    end

    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = ' ' .. (opts.title or 'Input') .. ' ',
        title_pos = 'center',
    })

    vim.api.nvim_win_set_option(winid, 'cursorline', true)

    -- Start in insert mode (scheduled to ensure it happens after window is fully set up)
    vim.schedule(function()
        if vim.api.nvim_win_is_valid(winid) then
            vim.cmd('startinsert')
        end
    end)

    -- Callback on submit
    vim.fn.prompt_setcallback(bufnr, function(text)
        vim.api.nvim_win_close(winid, true)
        if on_confirm then
            on_confirm(text)
        end
    end)

    -- Close on escape or ctrl-c
    vim.keymap.set('n', '<Esc>', function()
        vim.api.nvim_win_close(winid, true)
        if on_confirm then
            on_confirm(nil)
        end
    end, { buffer = bufnr })

    vim.keymap.set('i', '<C-c>', function()
        vim.api.nvim_win_close(winid, true)
        if on_confirm then
            on_confirm(nil)
        end
    end, { buffer = bufnr })
end

--- Floating window select
--- @param items table List of items to select from
--- @param opts table vim.ui.select options plus optional float options
--- @param on_select function Callback when item is selected
function M.select(items, opts, on_select)
    opts = opts or {}

    if not items or #items == 0 then
        if on_select then
            on_select(nil, nil)
        end
        return
    end

    -- Create floating window
    local width = opts.width or 60
    local height = math.min(#items + 2, math.floor(vim.o.lines * 0.8))

    local bufnr, winid = create_float({
        width = width,
        height = height,
        border = 'rounded',
        title = ' ' .. (opts.prompt or 'Select') .. ' ',
    })

    -- Format items
    local lines = {}
    local format_item = opts.format_item or tostring
    for i, item in ipairs(items) do
        lines[i] = string.format('%d. %s', i, format_item(item))
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(bufnr, 'filetype', 'nvim-agent-select')

    -- Selection keymaps
    local function select_item()
        local line = vim.api.nvim_win_get_cursor(winid)[1]
        local item = items[line]
        vim.api.nvim_win_close(winid, true)
        if on_select then
            on_select(item, line)
        end
    end

    local function cancel()
        vim.api.nvim_win_close(winid, true)
        if on_select then
            on_select(nil, nil)
        end
    end

    -- Keymaps
    vim.keymap.set('n', '<CR>', select_item, { buffer = bufnr })
    vim.keymap.set('n', '<Esc>', cancel, { buffer = bufnr })
    vim.keymap.set('n', 'q', cancel, { buffer = bufnr })

    -- Number keymaps for quick selection
    for i = 1, math.min(9, #items) do
        vim.keymap.set('n', tostring(i), function()
            if items[i] then
                vim.api.nvim_win_close(winid, true)
                if on_select then
                    on_select(items[i], i)
                end
            end
        end, { buffer = bufnr })
    end
end

--- Open content in a read-only floating buffer for viewing
--- @param content string|table Content to display (string or lines table)
--- @param opts table Options (title, filetype, etc.)
function M.view_readonly(content, opts)
    opts = opts or {}

    local bufnr, winid = create_float({
        width = opts.width or math.floor(vim.o.columns * 0.8),
        height = opts.height or math.floor(vim.o.lines * 0.8),
        border = 'rounded',
        title = ' ' .. (opts.title or 'View') .. ' ',
    })

    -- Set content
    local lines = type(content) == 'table' and content or vim.split(content, '\n')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Set as read-only
    vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(bufnr, 'readonly', true)

    if opts.filetype then
        vim.api.nvim_buf_set_option(bufnr, 'filetype', opts.filetype)
    end

    -- Add help text at bottom
    vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
    local help_text = '--- Press "e" to edit, "q" or <Esc> to close ---'
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {'', help_text})
    vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)

    -- Keymaps
    vim.keymap.set('n', 'q', function()
        vim.api.nvim_win_close(winid, true)
    end, { buffer = bufnr, desc = 'Close view' })

    vim.keymap.set('n', '<Esc>', function()
        vim.api.nvim_win_close(winid, true)
    end, { buffer = bufnr, desc = 'Close view' })

    -- Edit keymap
    if opts.on_edit then
        vim.keymap.set('n', 'e', function()
            vim.api.nvim_win_close(winid, true)
            opts.on_edit()
        end, { buffer = bufnr, desc = 'Edit' })
    end

    return bufnr, winid
end

--- Open file in a read-only buffer for viewing
--- @param filepath string Path to file
--- @param opts table Options (title, etc.)
function M.view_file(filepath, opts)
    opts = opts or {}

    local f = io.open(filepath, 'r')
    if not f then
        vim.notify('nvim-agent: failed to open file: ' .. filepath, vim.log.levels.ERROR)
        return
    end

    local content = f:read('*a')
    f:close()

    -- Detect filetype from extension
    local filetype = opts.filetype or vim.filetype.match({ filename = filepath })

    return M.view_readonly(content, {
        title = opts.title or vim.fn.fnamemodify(filepath, ':t'),
        filetype = filetype,
        width = opts.width,
        height = opts.height,
        on_edit = opts.on_edit or function()
            vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
        end,
    })
end

--- Edit file in a new buffer (helper for context editing)
--- @param filepath string Path to file
--- @param opts table Options
function M.edit_file(filepath, opts)
    opts = opts or {}

    -- Ensure file exists
    local f = io.open(filepath, 'r')
    if not f and opts.create_if_missing then
        f = io.open(filepath, 'w')
        if f then
            f:write(opts.default_content or '')
            f:close()
        end
    elseif f then
        f:close()
    end

    -- Open in current window or split
    if opts.split then
        vim.cmd('split ' .. vim.fn.fnameescape(filepath))
    elseif opts.vsplit then
        vim.cmd('vsplit ' .. vim.fn.fnameescape(filepath))
    else
        vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
    end
end

return M
