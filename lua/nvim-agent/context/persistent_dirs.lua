local M = {}

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

function M.load(path)
    local content = read_file(path)
    if not content or content == "" then
        return {}
    end
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

function M.save(entries, path)
    local json = vim.json.encode(entries)
    write_file(path, json)
end

return M
