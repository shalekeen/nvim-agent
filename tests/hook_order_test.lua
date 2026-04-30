-- Hook output ordering test for nvim-agent.
-- Run with: nvim -l tests/hook_order_test.lua
--
-- The UserPromptSubmit hook script emits context sections in a deliberate
-- stable→volatile order so Anthropic's automatic prefix cache can reuse the
-- longest possible prefix between consecutive prompts. This test populates a
-- sandbox with every section's source file, runs the hook, and asserts each
-- `--- <section> ---` marker appears in the expected position.

-- ---------------------------------------------------------------------------
-- Bootstrap.
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

-- ---------------------------------------------------------------------------
-- Test harness.
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

-- ---------------------------------------------------------------------------
-- 1. Extract the hook body from claude_code.lua source.
--    The function is local, so we can't call it directly — we read the source
--    and pull the heredoc content out.
-- ---------------------------------------------------------------------------

local source_path = plugin_root .. "/lua/nvim-agent/adapter/claude_code.lua"
local sf = io.open(source_path, "r")
check("claude_code.lua is readable", sf ~= nil)
if not sf then
	print(string.format("\n%d/%d checks passed", total - fail_count, total))
	os.exit(1)
end
local source = sf:read("*a")
sf:close()

local hook_script = source:match("local function hook_script_content%(%).-return %[%[(.-)%]%]")
check("extracted hook body from source", hook_script ~= nil and hook_script:find("NEOVIM EDITOR CONTEXT") ~= nil)
if not hook_script then
	print(string.format("\n%d/%d checks passed", total - fail_count, total))
	os.exit(1)
end

-- ---------------------------------------------------------------------------
-- 2. Build a sandbox where every section has a source file present, so we
--    can observe each section in the output. Sections with missing source
--    files are silently skipped by the hook, which would mask ordering bugs.
-- ---------------------------------------------------------------------------

local sandbox = vim.fn.tempname()
local active_dir = sandbox .. "/sessions/12345/Alice/active"
local process_dir = sandbox .. "/sessions/12345"
local cwd = sandbox .. "/project"
vim.fn.mkdir(active_dir, "p")
vim.fn.mkdir(cwd .. "/.nvim-agent/messages", "p")
vim.fn.mkdir(cwd .. "/.nvim-agent/status", "p")
vim.fn.mkdir(cwd .. "/.nvim-agent/history", "p")

local function write(path, content)
	local f = io.open(path, "w")
	f:write(content)
	f:close()
end

-- One file per emitted section, populated with content the hook will detect.
write(active_dir .. "/role.md", "lead implementer\n")
write(cwd .. "/PROJECT.md", "# Project\n")
write(active_dir .. "/.flavor_meta.json", '{"flavor":"dev"}')
write(active_dir .. "/persistent_dirs.json", "[]")
write(active_dir .. "/user_notes.md", "# Notes\n")
write(cwd .. "/.nvim-agent/history/Alice.md", "log entry\n")
write(process_dir .. "/tmux_captures.json", '[{"pane":"main"}]')
write(cwd .. "/.nvim-agent/status/Bob.json", '{"agent":"Bob","role":"reviewer","current_task":"reading","updated_at":"2026-01-01T00:00:00Z"}')
write(cwd .. "/.nvim-agent/messages/Alice.md", "ping")
write(process_dir .. "/ephemeral.json", '{"buffers":[]}')

-- Drop the hook into the sandbox so we don't touch the user's installed
-- ~/.nvim-agent/hooks copy.
local hook_path = sandbox .. "/hook.sh"
write(hook_path, hook_script)
vim.fn.system("chmod +x " .. vim.fn.shellescape(hook_path))

-- ---------------------------------------------------------------------------
-- 3. Run the hook and capture stdout.
-- ---------------------------------------------------------------------------

local cmd = string.format(
	"NVIM_AGENT_ACTIVE_DIR=%s NVIM_AGENT_PROCESS_DIR=%s NVIM_AGENT_CWD=%s bash %s 2>&1",
	vim.fn.shellescape(active_dir),
	vim.fn.shellescape(process_dir),
	vim.fn.shellescape(cwd),
	vim.fn.shellescape(hook_path)
)
local output = vim.fn.system(cmd)
check("hook produced non-empty output", output and #output > 0)
check("hook output contains the static header", output:find("NEOVIM EDITOR CONTEXT") ~= nil)
check("hook output contains the end marker", output:find("END NEOVIM CONTEXT") ~= nil)

-- ---------------------------------------------------------------------------
-- 4. Walk the output and pick out each `--- <section> ---` marker in order.
--    The first whitespace-delimited token after `---` is the section name;
--    we deliberately stop there so we don't get confused by suffixes like
--    "agent_history.md (last 40 lines)".
-- ---------------------------------------------------------------------------

local found = {}
for line in output:gmatch("[^\n]+") do
	local section = line:match("^%-%-%- (%S+)")
	if section then
		table.insert(found, section)
	end
end

-- Expected stable→volatile order. Most stable first; ephemeral.json (rewritten
-- on every BufEnter) must be last for the prefix cache to remain effective.
local expected = {
	"role.md",
	"PROJECT.md",
	".flavor_meta.json",
	"persistent_dirs.json",
	"user_notes.md",
	"agent_history.md",
	"tmux_captures.json",
	"peer_agents",
	"messages_for_you.md",
	"ephemeral.json",
}

check(
	"emitted exactly the expected number of sections",
	#found == #expected,
	string.format("expected %d, got %d (%s)", #expected, #found, table.concat(found, ", "))
)

for i, want in ipairs(expected) do
	local got = found[i] or "<missing>"
	check(string.format("section %d is %s", i, want), got == want, "got " .. got)
end

-- Cross-check the cache-friendly invariant explicitly: ephemeral.json is the
-- *only* section that may legitimately differ between prompts in a typical
-- single-agent flow, so it must be the very last one.
check(
	"ephemeral.json is the final section (cache-friendly invariant)",
	found[#found] == "ephemeral.json",
	"got " .. (found[#found] or "<none>")
)

-- ---------------------------------------------------------------------------
-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
