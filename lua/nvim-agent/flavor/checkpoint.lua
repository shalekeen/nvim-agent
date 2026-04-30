local M = {}

local config = require("nvim-agent.config")

local CONTEXT_FILES = { "system_prompt.md", "user_notes.md", "persistent_dirs.json" }
local META_FILE = ".flavor_meta.json"

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

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

local function copy_file(src, dst)
    local content = read_file(src)
    if content then
        write_file(dst, content)
        return true
    end
    return false
end

local function flavor_dir(name)
    return config.get().base_dir .. "/" .. name
end

local function checkpoint_dir(flavor_name, checkpoint_name)
    return flavor_dir(flavor_name) .. "/checkpoints/" .. checkpoint_name
end

local function write_meta(flavor_name, checkpoint_name, active_dir)
    if not active_dir then return end
    local meta = { flavor = flavor_name, checkpoint = checkpoint_name }
    write_file(active_dir .. "/" .. META_FILE, vim.json.encode(meta))
end

--- Sync persistent_dirs: update shared tags from base, keep checkpoint-only tags
local function sync_persistent_dirs(base_json, checkpoint_json)
    local ok_b, base_data = pcall(vim.json.decode, base_json or "[]")
    if not ok_b then
        base_data = {}
    end
    local ok_c, cp_data = pcall(vim.json.decode, checkpoint_json or "[]")
    if not ok_c then
        cp_data = {}
    end

    -- Build map of base tags
    local base_map = {}
    for _, entry in ipairs(base_data) do
        if entry.tag then
            base_map[entry.tag] = entry
        end
    end

    -- Build result: for each checkpoint entry, use base version if exists, else keep checkpoint
    local result = {}
    local processed_tags = {}

    for _, entry in ipairs(cp_data) do
        if entry.tag then
            if base_map[entry.tag] then
                table.insert(result, base_map[entry.tag])
            else
                table.insert(result, entry)
            end
            processed_tags[entry.tag] = true
        end
    end

    -- Add any base tags that weren't in checkpoint
    for _, entry in ipairs(base_data) do
        if entry.tag and not processed_tags[entry.tag] then
            table.insert(result, entry)
        end
    end

    return vim.json.encode(result)
end

--- Sync user_notes: update shared sections from base, keep checkpoint-only sections.
--- A "section" is a block of lines starting with `## <tag>` and continuing until the
--- next `##` header. The block of lines before the first `##` is the file's header.
--- Sections present in both files are taken from base; sections present only in the
--- checkpoint are preserved as-is.
local function sync_user_notes(base_content, checkpoint_content)
    local function split_lines(s)
        return vim.split(s or "", "\n", { plain = true })
    end

    local function append_lines(dst, src)
        for _, ln in ipairs(src) do
            table.insert(dst, ln)
        end
    end

    -- Parse <content> into { header_lines, ordered_tags, sections_by_tag }.
    -- header_lines  = the lines before any `##` header (kept as-is)
    -- ordered_tags  = tags in their original order
    -- sections      = tag → array of lines (including the `## ` header line itself)
    local function parse(content)
        local header_lines = {}
        local ordered_tags = {}
        local sections = {}
        local current_tag = nil
        for _, line in ipairs(split_lines(content)) do
            local tag = line:match("^## (.+)")
            if tag then
                current_tag = tag
                table.insert(ordered_tags, tag)
                sections[tag] = { line }
            elseif current_tag then
                table.insert(sections[current_tag], line)
            else
                table.insert(header_lines, line)
            end
        end
        return header_lines, ordered_tags, sections
    end

    local _, _, base_sections = parse(base_content)
    local cp_header, cp_tags, cp_sections = parse(checkpoint_content)

    local result = {}
    append_lines(result, cp_header)
    for _, tag in ipairs(cp_tags) do
        append_lines(result, base_sections[tag] or cp_sections[tag])
    end
    return table.concat(result, "\n")
end

--- Load checkpoint by copying all files to active_dir.
--- @param flavor_name string
--- @param checkpoint_name string
--- @param active_dir string|nil  Destination active dir (defaults to global active_dir)
function M.load(flavor_name, checkpoint_name, active_dir)
    local cp_dir = checkpoint_dir(flavor_name, checkpoint_name)

    if vim.fn.isdirectory(cp_dir) ~= 1 then
        vim.notify("nvim-agent: checkpoint '" .. checkpoint_name .. "' not found", vim.log.levels.ERROR)
        return false
    end

    if not active_dir then
        vim.notify("nvim-agent: active_dir required to load checkpoint", vim.log.levels.ERROR)
        return false
    end

    for _, fname in ipairs(CONTEXT_FILES) do
        local src = cp_dir .. "/" .. fname
        local dst = active_dir .. "/" .. fname

        if vim.fn.filereadable(src) == 1 then
            copy_file(src, dst)
        else
            vim.notify("nvim-agent: warning - missing file in checkpoint: " .. fname, vim.log.levels.WARN)
            if fname:match("%.json$") then
                write_file(dst, "[]")
            else
                write_file(dst, "")
            end
        end
    end

    write_meta(flavor_name, checkpoint_name, active_dir)
    return true
end

function M.list(flavor_name)
    local cp_base = flavor_dir(flavor_name) .. "/checkpoints"
    if vim.fn.isdirectory(cp_base) ~= 1 then
        return {}
    end
    local entries = vim.fn.readdir(cp_base)
    local checkpoints = {}
    for _, entry in ipairs(entries) do
        if vim.fn.isdirectory(cp_base .. "/" .. entry) == 1 and not entry:match("^%.") then
            table.insert(checkpoints, entry)
        end
    end
    table.sort(checkpoints)
    return checkpoints
end

function M.delete(flavor_name, checkpoint_name)
    local cp_dir = checkpoint_dir(flavor_name, checkpoint_name)
    if vim.fn.isdirectory(cp_dir) ~= 1 then
        vim.notify("nvim-agent: checkpoint '" .. checkpoint_name .. "' not found", vim.log.levels.ERROR)
        return false
    end
    vim.fn.delete(cp_dir, "rf")
    return true
end

--- Save current active_dir context to a specific checkpoint.
--- @param flavor_name string
--- @param checkpoint_name string
--- @param active_dir string|nil  Source active dir (defaults to global active_dir)
function M.save_to(flavor_name, checkpoint_name, active_dir)
    if not active_dir then
        vim.notify("nvim-agent: active_dir required to save checkpoint", vim.log.levels.ERROR)
        return false
    end

    local cp_dir = checkpoint_dir(flavor_name, checkpoint_name)
    if vim.fn.isdirectory(cp_dir) ~= 1 then
        vim.fn.mkdir(cp_dir, "p")
    end

    local success = true
    for _, fname in ipairs(CONTEXT_FILES) do
        local src = active_dir .. "/" .. fname
        local dst = cp_dir .. "/" .. fname

        if vim.fn.filereadable(src) == 1 then
            if not copy_file(src, dst) then
                success = false
            end
        else
            vim.notify("nvim-agent: warning - missing file in active context: " .. fname, vim.log.levels.WARN)
            if fname:match("%.json$") then
                write_file(dst, "[]")
            else
                write_file(dst, "")
            end
        end
    end

    return success
end

--- Sync checkpoint with base: update shared context elements from base, keep checkpoint-only elements.
--- @param flavor_name string
--- @param checkpoint_name string
--- @param active_dir string|nil  Active dir for meta update (defaults to global active_dir)
function M.sync_with_base(flavor_name, checkpoint_name, active_dir)
    local fdir = flavor_dir(flavor_name)
    local cp_dir = checkpoint_dir(flavor_name, checkpoint_name)

    if vim.fn.isdirectory(fdir) ~= 1 then
        vim.notify("nvim-agent: base flavor '" .. flavor_name .. "' not found", vim.log.levels.ERROR)
        return false
    end

    if vim.fn.isdirectory(cp_dir) ~= 1 then
        vim.notify("nvim-agent: checkpoint '" .. checkpoint_name .. "' not found", vim.log.levels.ERROR)
        return false
    end

    -- For each context file, sync from base
    for _, fname in ipairs(CONTEXT_FILES) do
        local base_file = fdir .. "/" .. fname
        local cp_file = cp_dir .. "/" .. fname

        local base_content = read_file(base_file) or ""
        local cp_content = read_file(cp_file) or ""

        local synced_content
        if fname == "persistent_dirs.json" then
            synced_content = sync_persistent_dirs(base_content, cp_content)
        elseif fname == "user_notes.md" then
            synced_content = sync_user_notes(base_content, cp_content)
        elseif fname == "system_prompt.md" then
            synced_content = base_content
        else
            synced_content = cp_content
        end

        write_file(cp_file, synced_content)
    end

    -- Also update active_dir if this checkpoint is currently loaded there
    if active_dir then
        local meta_path = active_dir .. "/" .. META_FILE
        local meta_content = read_file(meta_path)
        if meta_content then
            local ok, meta = pcall(vim.json.decode, meta_content)
            if ok and meta.checkpoint == checkpoint_name and meta.flavor == flavor_name then
                -- This checkpoint is active, update active directory too
                M.load(flavor_name, checkpoint_name, active_dir)
            end
        end
    end

    return true
end

return M
