-- Tests for lua/nvim-agent/mcp/buffer_ops.lua — the core algorithm behind
-- the edit_buffer MCP tool.
-- Run with: nvim -l tests/edit_buffer_test.lua
--
-- Pins down the bug fix where edit_buffer used to close the user's
-- actively-edited buffer out from under them. Now:
--   - Buffer already open in editor    → edit in place, leave open
--   - No buffer existed                → create ephemeral, edit, close
--   - review=true                      → always leave open + position cursor

-- ---------------------------------------------------------------------------
-- Bootstrapping.
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

vim.opt.runtimepath:append(plugin_root)

-- ---------------------------------------------------------------------------
-- Tiny test harness.
-- ---------------------------------------------------------------------------

local fail_count = 0
local total = 0

local function check(label, ok, detail)
	total = total + 1
	if ok then
		print("PASS " .. label)
	else
		print("FAIL " .. label .. (detail and (" — " .. detail) or ""))
		fail_count = fail_count + 1
	end
end

local function assert_eq(label, actual, expected)
	check(label, actual == expected, string.format("expected %q, got %q", tostring(expected), tostring(actual)))
end

local function read(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local c = f:read("*a")
	f:close()
	return c
end

local function write(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	f:write(content)
	f:close()
end

--- Return true if any loaded buffer's canonical name matches `path`.
local function any_buffer_loaded_for(path)
	local abs = vim.fn.fnamemodify(path, ":p")
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
			return true, b
		end
	end
	return false, nil
end

-- ---------------------------------------------------------------------------
-- Test sandbox.
-- ---------------------------------------------------------------------------

local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")

local buffer_ops = require("nvim-agent.mcp.buffer_ops")

-- ---------------------------------------------------------------------------
-- 1. THE BUG: user has a file open, agent edits it.
-- The buffer MUST survive — closing it would yank it out from under the user.
-- ---------------------------------------------------------------------------

local path1 = sandbox .. "/open-in-editor.txt"
write(path1, "original line 1\noriginal line 2\noriginal line 3\n")

-- User opens it in the editor (simulated by adding to the buffer list).
vim.cmd("edit " .. vim.fn.fnameescape(path1))
local user_bufnr = vim.fn.bufnr(path1)
check("setup: buffer is loaded for the open file", vim.api.nvim_buf_is_loaded(user_bufnr))

local result1 = buffer_ops.edit({
	filepath = path1,
	new_lines = { "edited line 1", "edited line 2", "edited line 3" },
	save = true,
	review = false,
})

assert_eq("bug fix: was_already_open = true when user has file open", result1.was_already_open, true)
assert_eq("bug fix: closed = false when buffer was already open", result1.closed, false)
check("bug fix: buffer survives the edit (still loaded)", vim.api.nvim_buf_is_loaded(user_bufnr))
assert_eq("bug fix: edit returned same bufnr the user already had", result1.bufnr, user_bufnr)
assert_eq("file on disk has new content", read(path1), "edited line 1\nedited line 2\nedited line 3\n")

-- ---------------------------------------------------------------------------
-- 2. INVERSE: no buffer existed → ephemeral buffer is closed after edit.
-- ---------------------------------------------------------------------------

local path2 = sandbox .. "/not-open-anywhere.txt"
write(path2, "original\n")

-- Sanity: no buffer for this file exists yet.
local pre_loaded = any_buffer_loaded_for(path2)
check("setup: no buffer loaded for path2 before edit", not pre_loaded)

local result2 = buffer_ops.edit({
	filepath = path2,
	new_lines = { "new content" },
	save = true,
	review = false,
})

assert_eq("was_already_open = false when no buffer pre-existed", result2.was_already_open, false)
assert_eq("closed = true (ephemeral buffer cleaned up)", result2.closed, true)
local post_loaded = any_buffer_loaded_for(path2)
check("no buffer left loaded for path2 after edit", not post_loaded)
assert_eq("file on disk has new content", read(path2), "new content\n")

-- ---------------------------------------------------------------------------
-- 3. Range edit on a pre-existing buffer: only the range is replaced.
-- ---------------------------------------------------------------------------

local path3 = sandbox .. "/range-edit.txt"
write(path3, "line A\nline B\nline C\nline D\nline E\n")
vim.cmd("edit " .. vim.fn.fnameescape(path3))
local range_bufnr = vim.fn.bufnr(path3)

local result3 = buffer_ops.edit({
	filepath = path3,
	new_lines = { "REPLACED-B-and-C" },
	start_line = 2,
	end_line = 3,
	save = true,
	review = false,
})

assert_eq("range edit on pre-existing: was_already_open = true", result3.was_already_open, true)
assert_eq("range edit on pre-existing: closed = false", result3.closed, false)
check("range edit buffer still loaded", vim.api.nvim_buf_is_loaded(range_bufnr))
assert_eq("range edit replaced only lines 2-3", read(path3), "line A\nREPLACED-B-and-C\nline D\nline E\n")

-- ---------------------------------------------------------------------------
-- 4. review=true with NO pre-existing buffer: buffer is created AND kept
-- open so the user can inspect it. This is the "show me what you changed"
-- workflow.
-- ---------------------------------------------------------------------------

local path4 = sandbox .. "/review-mode.txt"
write(path4, "before review\n")

local pre_loaded4 = any_buffer_loaded_for(path4)
check("setup: no buffer for path4 before edit", not pre_loaded4)

local result4 = buffer_ops.edit({
	filepath = path4,
	new_lines = { "after review" },
	save = true,
	review = true,
})

assert_eq("review mode: was_already_open = false (we opened it)", result4.was_already_open, false)
assert_eq("review mode: closed = false (we leave it open for inspection)", result4.closed, false)
local post_loaded4 = any_buffer_loaded_for(path4)
check("review mode: buffer LEFT open after edit", post_loaded4)

-- ---------------------------------------------------------------------------
-- 5. New file creation: path doesn't exist on disk yet.
-- buffer_ops should create the file with the right content AND not leave
-- a buffer behind (review=false).
-- ---------------------------------------------------------------------------

local path5 = sandbox .. "/subdir/that/does/not/exist/new-file.txt"
check("setup: path5 does not exist", vim.fn.filereadable(path5) == 0)
check("setup: parent dir does not exist", vim.fn.isdirectory(vim.fn.fnamemodify(path5, ":h")) == 0)

local result5 = buffer_ops.edit({
	filepath = path5,
	new_lines = { "freshly created" },
	save = true,
	review = false,
})

assert_eq("new file: was_already_open = false", result5.was_already_open, false)
assert_eq("new file: closed = true", result5.closed, true)
check("new file: parent dir was created", vim.fn.isdirectory(vim.fn.fnamemodify(path5, ":h")) == 1)
assert_eq("new file: written to disk", read(path5), "freshly created\n")
local left_open5 = any_buffer_loaded_for(path5)
check("new file: no buffer left loaded", not left_open5)

-- ---------------------------------------------------------------------------
-- 6. Idempotence: re-running edit on the SAME pre-existing buffer keeps
-- giving the same was_already_open=true / closed=false answer.
-- Guards against a subtle bug where the algorithm might mark a buffer as
-- "ephemeral" on a second call because some state got cleared on round 1.
-- ---------------------------------------------------------------------------

local result1b = buffer_ops.edit({
	filepath = path1,
	new_lines = { "rev 2" },
	save = true,
	review = false,
})

assert_eq("re-edit: was_already_open still true", result1b.was_already_open, true)
assert_eq("re-edit: closed still false", result1b.closed, false)
check("re-edit: original user buffer STILL loaded", vim.api.nvim_buf_is_loaded(user_bufnr))
assert_eq("re-edit: file on disk reflects second edit", read(path1), "rev 2\n")

-- ---------------------------------------------------------------------------
-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
