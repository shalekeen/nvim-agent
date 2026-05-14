-- Per-project "last used flavor" memory.
--
-- This file is the only piece of state that crosses Neovim restarts and
-- powers the "Use Active — <flavor>" default in the startup picker plus
-- the auto_launch fast path.
--
-- BUG FIX HISTORY: previous versions stored a single global file at
-- ~/.nvim-agent/last_flavor.json. Two simultaneous Neovim instances in
-- different cwds would trample each other's choice — whoever wrote last
-- decided what BOTH would see on next startup. Now scoped per-cwd by
-- writing to ~/.nvim-agent/last_flavor/<sanitized-cwd>.json.

local M = {}

local config = require("nvim-agent.config")

--- Sanitize an absolute cwd path into a single safe filename component.
--- Replaces every char that isn't [a-zA-Z0-9._-] with "_".
---
--- Trade-off: two distinct cwds that differ only by chars-we-strip
--- (e.g. "/foo/bar" vs "/foo_bar") will collide. That's vanishingly rare
--- in real project trees and the alternative (sha-hashed names) loses
--- human readability when debugging via `ls`.
--- @param cwd string
--- @return string
local function sanitize(cwd)
	return (cwd:gsub("[^%w%-_%.]", "_"))
end

--- Return the per-cwd persistence file path.
--- @param cwd string|nil  Defaults to vim.fn.getcwd().
--- @return string         <base_dir>/last_flavor/<sanitized-cwd>.json
function M.path(cwd)
	cwd = cwd or vim.fn.getcwd()
	return config.get().base_dir .. "/last_flavor/" .. sanitize(cwd) .. ".json"
end

--- Write the last-used flavor/checkpoint for `cwd`. Creates the parent
--- dir on demand. Silent on I/O failure (best-effort persistence — losing
--- this file just means the next startup falls through to the full picker).
--- @param cwd string|nil
--- @param flavor_name string
--- @param checkpoint_name string|nil
function M.persist(cwd, flavor_name, checkpoint_name)
	local path = M.path(cwd)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return
	end
	f:write(vim.json.encode({ flavor = flavor_name, checkpoint = checkpoint_name }))
	f:close()
end

--- Read the last-used flavor/checkpoint for `cwd`.
--- @param cwd string|nil
--- @return string|nil flavor_name      nil if no file or corrupt JSON
--- @return string|nil checkpoint_name  nil if no file or corrupt JSON
function M.read(cwd)
	local path = M.path(cwd)
	local f = io.open(path, "r")
	if not f then
		return nil, nil
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		return data.flavor, data.checkpoint
	end
	return nil, nil
end

return M
