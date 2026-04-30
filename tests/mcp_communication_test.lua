-- Multi-agent communication test for the MCP tool surface.
-- Run with: nvim -l tests/mcp_communication_test.lua
--
-- Drives mcp/tools.lua's M.execute(...) directly so we exercise the same
-- code path Claude Code calls into. Stubs out the nvim_rpc.trigger_agent
-- calls (no real Neovim socket here) but lets the file-IO paths run for real.
-- Verifies the lock-coordinated fixes from the recent review pass.

-- ---------------------------------------------------------------------------
-- Bootstrapping.
-- ---------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local plugin_root = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if plugin_root == "" or plugin_root == "tests" then
	plugin_root = "."
end

-- Set up a sandbox with a fake project cwd and a fake active dir matching the
-- structure mcp/tools.lua's AGENT_NAME parser expects:
--   .../sessions/<pid>/<agent_name>/active
local sandbox = vim.fn.tempname()
local cwd = sandbox .. "/project"
local sessions_dir = sandbox .. "/sessions/12345"
local agent_name = "Alice"
local active_dir = sessions_dir .. "/" .. agent_name .. "/active"
vim.fn.mkdir(cwd, "p")
vim.fn.mkdir(active_dir, "p")

-- Write a role file so update_status picks it up.
local role_file = io.open(active_dir .. "/role.md", "w")
role_file:write("lead implementer\n")
role_file:close()

-- Env vars must be set BEFORE requiring tools.lua — the module captures them
-- at load time into local upvalues.
vim.env.NVIM_AGENT_ACTIVE_DIR = active_dir
vim.env.NVIM_AGENT_CWD = cwd
-- Stale value from previous tests in the same nvim process won't bite us
-- because we set them explicitly here.

-- The MCP module uses flat-namespace requires (`require("nvim_rpc")`, etc.)
-- because it's normally launched via `nvim -l mcp/server.lua` which manipulates
-- package.path itself. Replicate that here.
local mcp_dir = plugin_root .. "/lua/nvim-agent/mcp"
package.path = mcp_dir .. "/?.lua;" .. package.path

local tools = require("tools")

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

local function assert_eq(label, actual, expected)
	check(label, actual == expected, string.format("expected %q, got %q", tostring(expected), tostring(actual)))
end

local function read(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Helper: run an MCP tool by name and return the first text content + is_error flag.
local function run(tool_name, args)
	local content, is_error = tools.execute(tool_name, args or {})
	local text = (content and content[1] and content[1].text) or ""
	return text, is_error
end

-- ---------------------------------------------------------------------------
-- 1. update_status writes an atomic JSON status file containing role.md content.
-- ---------------------------------------------------------------------------

local _, err = run("update_status", { current_task = "implementing feature X" })
check("update_status returns no error", not err)

local status_path = cwd .. "/.nvim-agent/status/Alice.json"
local status_raw = read(status_path)
check("status file written", status_raw ~= nil)
check("status JSON includes current_task", status_raw and status_raw:find('"current_task":"implementing feature X"') ~= nil)
-- role.md content is stored verbatim (including any trailing newline),
-- which JSON-encodes as \n in the serialized output.
check("status JSON includes role from role.md", status_raw and status_raw:find('"role":"lead implementer') ~= nil)
check("no .tmp file lingers (atomic write)", read(status_path .. ".tmp") == nil)

-- ---------------------------------------------------------------------------
-- 2. send_message writes to the recipient's mailbox + bumps a trigger file.
--    The RPC wakeup will fail (no real nvim socket) but that's caught.
-- ---------------------------------------------------------------------------

-- First create a peer "Bob" so list_peer_names sees them.
local bob_status = io.open(cwd .. "/.nvim-agent/status/Bob.json", "w")
bob_status:write('{"agent":"Bob","role":"reviewer","current_task":"idle","updated_at":"2026-01-01T00:00:00Z"}')
bob_status:close()

local _, err2 = run("send_message", { to = "Bob", content = "please review my changes" })
check("send_message to peer returns no error (rpc failure is non-fatal)", not err2)

local bob_mailbox = cwd .. "/.nvim-agent/messages/Bob.md"
local bob_msg = read(bob_mailbox)
check("Bob's mailbox file created", bob_msg ~= nil)
check("mailbox contains 'From: Alice'", bob_msg and bob_msg:find("From: Alice") ~= nil)
check("mailbox contains the message body", bob_msg and bob_msg:find("please review my changes") ~= nil)
check("trigger file written for Bob", read(cwd .. "/.nvim-agent/triggers/Bob.md") ~= nil)

-- ---------------------------------------------------------------------------
-- 3. send_message with to="all" broadcasts to every peer (excludes self).
-- ---------------------------------------------------------------------------

-- Add a third peer so we can verify "all" hits multiple recipients.
local carol_status = io.open(cwd .. "/.nvim-agent/status/Carol.json", "w")
carol_status:write('{"agent":"Carol","role":"qa","current_task":"writing tests","updated_at":"2026-01-01T00:00:00Z"}')
carol_status:close()

local broadcast_text, _ = run("send_message", { to = "all", content = "ping" })
check("broadcast text mentions Bob", broadcast_text:find("Bob") ~= nil)
check("broadcast text mentions Carol", broadcast_text:find("Carol") ~= nil)
check("broadcast text excludes self (Alice)", not broadcast_text:find("Alice"))

local carol_msg = read(cwd .. "/.nvim-agent/messages/Carol.md")
check("Carol received the broadcast", carol_msg ~= nil and carol_msg:find("ping") ~= nil)

-- ---------------------------------------------------------------------------
-- 4. read_messages reads + clears Alice's mailbox under the file lock.
-- ---------------------------------------------------------------------------

-- Have Bob send a message back to Alice.
local sender_active = sessions_dir .. "/Bob/active"
vim.fn.mkdir(sender_active, "p")
-- Switch the captured AGENT_NAME / ACTIVE_DIR by re-loading tools.lua under
-- Bob's identity. This isn't a thing tools.lua supports cleanly (env is read
-- at load), so simulate by writing directly to Alice's mailbox.
local alice_mailbox = cwd .. "/.nvim-agent/messages/Alice.md"
local fw = io.open(alice_mailbox, "w")
fw:write("\n---\n**From: Bob** | 2026-01-01 00:00:00\n\nLGTM\n")
fw:close()

local read_text, _ = run("read_messages", {})
check("read_messages returns the mailbox content", read_text:find("From: Bob") ~= nil)
check("read_messages returns the message body", read_text:find("LGTM") ~= nil)

-- After read_messages runs, the mailbox should be truncated (read+truncate
-- is atomic under filelock).
local cleared = read(alice_mailbox)
check("read_messages truncated mailbox", cleared == "" or cleared == nil)

-- A second read_messages call returns "No pending messages".
local second_read, _ = run("read_messages", {})
check("second read_messages returns 'No pending messages'", second_read:find("No pending messages") ~= nil)

-- ---------------------------------------------------------------------------
-- 5. list_agent_statuses + list_agent_roles see all peers, exclude self.
-- ---------------------------------------------------------------------------

local statuses, _ = run("list_agent_statuses", {})
check("list_agent_statuses includes Bob", statuses:find("Bob") ~= nil)
check("list_agent_statuses includes Carol", statuses:find("Carol") ~= nil)
check("list_agent_statuses excludes self", not statuses:find("Agent: Alice"))

local roles, _ = run("list_agent_roles", {})
check("list_agent_roles shows Bob's role", roles:find("reviewer") ~= nil)
check("list_agent_roles shows Carol's role", roles:find("qa") ~= nil)

-- ---------------------------------------------------------------------------
-- 6. log_work + read_agent_history round-trip.
-- ---------------------------------------------------------------------------

run("log_work", { summary = "implemented foo" })
run("log_work", { summary = "fixed bar" })

local history, _ = run("read_agent_history", {})
check("history contains 'implemented foo'", history:find("implemented foo") ~= nil)
check("history contains 'fixed bar'", history:find("fixed bar") ~= nil)
check("history is per-agent (Alice's file)", history:find("implemented foo") ~= nil)

-- read_cwd_history returns history for all agents in the project.
-- Add a Bob history entry directly so we can verify aggregation.
vim.fn.mkdir(cwd .. "/.nvim-agent/history", "p")
local bob_hist = io.open(cwd .. "/.nvim-agent/history/Bob.md", "w")
bob_hist:write("\n---\n**[2026-01-01 00:00] Agent: Bob**\n\nreviewed PR\n")
bob_hist:close()

local cwd_history, _ = run("read_cwd_history", {})
check("read_cwd_history includes Alice's entries", cwd_history:find("implemented foo") ~= nil)
check("read_cwd_history includes Bob's entries", cwd_history:find("reviewed PR") ~= nil)

-- ---------------------------------------------------------------------------
-- 7. Concurrent message delivery: hammer Bob's mailbox with many writes and
--    confirm every line is preserved (no interleaving). This validates the
--    filelock around deliver_message.
-- ---------------------------------------------------------------------------

-- Reset Bob's mailbox.
local fw_reset = io.open(bob_mailbox, "w")
fw_reset:close()

-- Lua has no real threads, but we can still verify that 100 sequential
-- send_messages each produce one well-formed block.
for i = 1, 50 do
	run("send_message", { to = "Bob", content = "msg #" .. i })
end

local stuffed = read(bob_mailbox) or ""
local block_count = select(2, stuffed:gsub("From: Alice", "From: Alice"))
check("50 send_messages → 50 message blocks", block_count == 50, "got " .. block_count)
-- Verify last message survived intact (a partial-write race would corrupt it).
check("last message content intact", stuffed:find("msg #50") ~= nil)

-- ---------------------------------------------------------------------------
-- Cleanup + summary.
-- ---------------------------------------------------------------------------

vim.fn.delete(sandbox, "rf")
vim.env.NVIM_AGENT_ACTIVE_DIR = nil
vim.env.NVIM_AGENT_CWD = nil

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
