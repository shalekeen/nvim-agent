local M = {}

function M.load(path)
    local f = io.open(path, "r")
    if not f then
        return ""
    end
    local content = f:read("*a")
    f:close()
    return content
end

function M.save(content, path)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(content)
    f:close()
    return true
end

return M
