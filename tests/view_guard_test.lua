-- view_guard: an agent's actions inside Neovim never move the user's view.
-- Run with: nvim -l tests/view_guard_test.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local total, fail_count = 0, 0
local function check(label, ok, detail)
	total = total + 1
	if ok then print("PASS " .. label) else fail_count = fail_count + 1; print("FAIL " .. label .. (detail and (" — " .. tostring(detail)) or "")) end
end
local G = require("nvim-agent.mcp.view_guard")
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
local fa, fb = sandbox .. "/a.lua", sandbox .. "/b.lua"
vim.fn.writefile({ "a1", "a2", "a3" }, fa)
vim.fn.writefile({ "b1", "b2" }, fb)

-- Layout: left window = file a (cursor on line 2), right window = a terminal
-- (the "user is talking to an agent" window), which is current.
vim.cmd("edit " .. vim.fn.fnameescape(fa))
local file_win = vim.api.nvim_get_current_win()
local file_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(file_win, { 2, 1 })
vim.cmd("vsplit")
local term_win = vim.api.nvim_get_current_win()
local term_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(term_win, term_buf)
vim.fn.termopen({ "sh", "-c", "sleep 60" })
vim.bo[term_buf].filetype = "nvim-agent"
check("setup: terminal window is current", vim.api.nvim_get_current_win() == term_win and vim.bo[0].buftype == "terminal")

-- 1. :edit in the user's window is undone.
local ok, out, restored = G.run(function() return vim.fn.execute("edit " .. vim.fn.fnameescape(fb)) end)
check(":edit ran", ok, out)
check(":edit — user's window shows the terminal again", vim.api.nvim_win_get_buf(term_win) == term_buf and vim.api.nvim_get_current_win() == term_win)
check(":edit — restore reported the buffer swap", vim.tbl_contains(restored, "buffer shown in the user's window"), vim.inspect(restored))

-- 2. :split / :wincmd move focus; focus comes back, the extra window is left.
local wins_before = #vim.api.nvim_list_wins()
ok, out, restored = G.run(function() vim.cmd("split " .. vim.fn.fnameescape(fb)) end)
check(":split — focus returned to the user's window", vim.api.nvim_get_current_win() == term_win, vim.inspect(restored))
check(":split — reported the focus change", vim.tbl_contains(restored, "window focus"))
check(":split — the new window itself is left alone", #vim.api.nvim_list_wins() == wins_before + 1)
for _, w in ipairs(vim.api.nvim_list_wins()) do if w ~= term_win and w ~= file_win then vim.api.nvim_win_close(w, true) end end

-- 3. A harmless command restores nothing and reports nothing.
ok, out, restored = G.run(function() return vim.fn.execute("set number?") end)
check("harmless command: ok, nothing restored", ok and #restored == 0, vim.inspect(restored))

-- 4. Jumping to the file window (vsplit put the terminal on the LEFT) and
--    moving its cursor: focus comes back; the other window's cursor is the
--    agent's business, not the user's view.
ok, out, restored = G.run(function() vim.api.nvim_set_current_win(file_win); vim.api.nvim_win_set_cursor(0, { 3, 0 }) end)
check("focus moved to the file window and back", vim.api.nvim_get_current_win() == term_win and vim.tbl_contains(restored, "window focus"), vim.inspect(restored))
-- The agent moved the cursor in the OTHER window; that window's cursor is not ours to restore.
check("other window cursor keeps the agent's move (only the user's window is restored)", vim.api.nvim_win_get_cursor(file_win)[1] == 3)
vim.api.nvim_win_set_cursor(file_win, { 2, 1 })

-- 5. file_window: never the terminal.
local w, err = G.file_window(nil)
check("file_window(nil) from a terminal picks the file window", w == file_win, tostring(err))
w, err = G.file_window(fa)
check("file_window(path) finds the window showing that file", w == file_win)
w, err = G.file_window(fb)
check("file_window(path) errors for a file not shown", w == nil and err:find("not shown", 1, true) ~= nil, tostring(err))
vim.api.nvim_set_current_win(file_win)
check("file_window(nil) from a file window is that window", G.file_window(nil) == file_win)
vim.api.nvim_set_current_win(term_win)
vim.api.nvim_win_close(file_win, true)
w, err = G.file_window(nil)
check("file_window(nil) with no file window errors", w == nil and err:find("no file window", 1, true) ~= nil, tostring(err))

-- 6. The ephemeral last_file steers file_window when the user is in a terminal.
vim.cmd("vsplit " .. vim.fn.fnameescape(fb))
local fb_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit " .. vim.fn.fnameescape(fa))
local fa_win = vim.api.nvim_get_current_win()
require("nvim-agent.context.ephemeral").note_file_buffer(vim.api.nvim_win_get_buf(fb_win), fb_win)
vim.api.nvim_set_current_win(term_win)
check("file_window(nil) prefers the file the user was last in", G.file_window(nil) == fb_win)

pcall(vim.fn.jobstop, vim.bo[term_buf].channel)
vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then os.exit(1) end
