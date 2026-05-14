-- Buffer-editing primitives shared between mcp/nvim_rpc.lua and tests.
--
-- This module runs INSIDE the parent Neovim — i.e. it's invoked via
-- nvim_rpc.lua's remote-expr machinery from the MCP server subprocess.
-- Keeping the algorithm out of the inlined-Lua-string in nvim_rpc.lua
-- makes it directly testable from a regular `nvim -l tests/foo.lua`.

local M = {}

--- Apply a content edit to `filepath`. If a buffer for the file is already
--- loaded (the user has it open), the edit happens in place and the buffer
--- is LEFT ALONE. Otherwise an ephemeral buffer is created, edited, and
--- disposed of when we're done.
---
--- This split is the fix for the bug where `edit_buffer` was closing the
--- user's actively-edited buffer out from under them — a buffer-open in
--- the editor is sticky state we must respect.
---
--- @param opts table {
---     filepath     = string,          -- absolute or relative; we canonicalize
---     new_lines    = string[],        -- pre-split content lines
---     start_line   = integer|nil,     -- 1-indexed inclusive; nil = whole file
---     end_line     = integer|nil,     -- 1-indexed inclusive
---     save         = boolean,         -- whether to :write the buffer after editing
---     cursor_line  = integer|nil,     -- only honored in review mode
---     review       = boolean,         -- if true: leave buffer open + position cursor
--- }
--- @return table { bufnr: integer, closed: boolean, was_already_open: boolean, error?: string }
function M.edit(opts)
	local filepath = opts.filepath
	local new_lines = opts.new_lines
	local start_line = opts.start_line
	local end_line = opts.end_line
	local should_save = opts.save ~= false -- default true
	local cursor_line = opts.cursor_line
	local review = opts.review and true or false

	-- Ensure parent directory exists before loading/writing.
	local dir = vim.fn.fnamemodify(filepath, ":h")
	if dir and dir ~= "" then
		vim.fn.mkdir(dir, "p")
	end

	-- Detect whether the user already has this file open BEFORE we touch
	-- the buffer. Compare canonical absolute paths against every loaded
	-- buffer's name — `bufnr(path)` has gotchas with partial matches.
	-- If the buffer is already loaded, treat it as "owned by the user":
	-- we may edit and save, but we MUST NOT delete the buffer afterwards
	-- (that would yank it out from under them).
	local abs_path = vim.fn.fnamemodify(filepath, ":p")
	local was_already_open = false
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs_path then
			was_already_open = true
			break
		end
	end

	-- Load the buffer silently without switching any window.
	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)
	vim.bo[bufnr].buflisted = true

	-- Apply content: replace a range or the whole file.
	if start_line and end_line then
		vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)
	else
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	end

	if should_save then
		local ok, write_err = pcall(function()
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("write")
			end)
		end)
		if not ok then
			return {
				error = "write failed: " .. tostring(write_err),
				bufnr = bufnr,
				closed = false,
				was_already_open = was_already_open,
			}
		end
	end

	-- Position cursor if requested (only meaningful in review mode).
	if cursor_line and review then
		local target_win = nil
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == bufnr then
				target_win = win
				break
			end
		end
		if target_win then
			local line_count = vim.api.nvim_buf_line_count(bufnr)
			local safe_line = math.min(cursor_line, line_count)
			vim.api.nvim_win_set_cursor(target_win, { safe_line, 0 })
		end
	end

	-- Close the buffer ONLY if:
	--   - review mode is off (user didn't ask to inspect it), AND
	--   - we opened it ourselves (it's an ephemeral buffer the agent created).
	-- If was_already_open is true, the user is actively editing this file —
	-- leave their buffer alone.
	local closed = false
	if not review and not was_already_open then
		vim.bo[bufnr].buflisted = false
		pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
		closed = true
	end

	return { bufnr = bufnr, closed = closed, was_already_open = was_already_open }
end

return M
