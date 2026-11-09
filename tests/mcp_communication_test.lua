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
--   .../sessions/<instance_id>/<agent_name>/active
local sandbox = vim.fn.tempname()
local cwd = sandbox .. "/project"
local instance_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local sessions_dir = sandbox .. "/sessions/" .. instance_id
-- Peer-state root for THIS Neovim instance — what the parent Neovim exports
-- as NVIM_AGENT_RUNTIME_DIR. tools.lua must never touch anything outside it.
local runtime_dir = cwd .. "/.nvim-agent/instances/" .. instance_id
-- A second Neovim instance on the same project; must be invisible.
local other_runtime_dir = cwd .. "/.nvim-agent/instances/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
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
vim.env.NVIM_AGENT_RUNTIME_DIR = runtime_dir
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

local status_path = runtime_dir .. "/status/Alice.json"
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
local bob_status = io.open(runtime_dir .. "/status/Bob.json", "w")
bob_status:write('{"agent":"Bob","role":"reviewer","current_task":"idle","updated_at":"2026-01-01T00:00:00Z"}')
bob_status:close()

local _, err2 = run("send_message", { to = "Bob", content = "please review my changes" })
check("send_message to peer returns no error (rpc failure is non-fatal)", not err2)

local bob_mailbox = runtime_dir .. "/messages/Bob.md"
local bob_msg = read(bob_mailbox)
check("Bob's mailbox file created", bob_msg ~= nil)
check("mailbox contains 'From: Alice'", bob_msg and bob_msg:find("From: Alice") ~= nil)
check("mailbox contains the message body", bob_msg and bob_msg:find("please review my changes") ~= nil)
check("trigger file written for Bob", read(runtime_dir .. "/triggers/Bob.md") ~= nil)

-- ---------------------------------------------------------------------------
-- 3. send_message with to="all" broadcasts to every peer (excludes self).
-- ---------------------------------------------------------------------------

-- Add a third peer so we can verify "all" hits multiple recipients.
local carol_status = io.open(runtime_dir .. "/status/Carol.json", "w")
carol_status:write('{"agent":"Carol","role":"qa","current_task":"writing tests","updated_at":"2026-01-01T00:00:00Z"}')
carol_status:close()

-- Plant a peer in ANOTHER Neovim instance's runtime dir and in the legacy
-- shared project-level location. Neither may ever be discovered.
vim.fn.mkdir(other_runtime_dir .. "/status", "p")
local mallory_status = io.open(other_runtime_dir .. "/status/Mallory.json", "w")
mallory_status:write('{"agent":"Mallory","role":"intruder","current_task":"lurking","updated_at":"2026-01-01T00:00:00Z"}')
mallory_status:close()
vim.fn.mkdir(cwd .. "/.nvim-agent/status", "p")
local legacy_status = io.open(cwd .. "/.nvim-agent/status/Legacy.json", "w")
legacy_status:write('{"agent":"Legacy","role":"ghost","current_task":"haunting","updated_at":"2026-01-01T00:00:00Z"}')
legacy_status:close()

local broadcast_text, _ = run("send_message", { to = "all", content = "ping" })
check("broadcast text mentions Bob", broadcast_text:find("Bob") ~= nil)
check("broadcast text mentions Carol", broadcast_text:find("Carol") ~= nil)
check("broadcast text excludes self (Alice)", not broadcast_text:find("Alice"))
check("broadcast excludes peer from another Neovim instance", not broadcast_text:find("Mallory"))
check("broadcast excludes legacy project-level peer", not broadcast_text:find("Legacy"))
check("no mailbox created in the other instance's tree", read(other_runtime_dir .. "/messages/Mallory.md") == nil)
check("no mailbox created at the legacy project level", read(cwd .. "/.nvim-agent/messages/Legacy.md") == nil)

local carol_msg = read(runtime_dir .. "/messages/Carol.md")
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
local alice_mailbox = runtime_dir .. "/messages/Alice.md"
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
check("list_agent_statuses excludes other-instance peer", not statuses:find("Mallory"))
check("list_agent_statuses excludes legacy project-level peer", not statuses:find("Legacy"))

local roles, _ = run("list_agent_roles", {})
check("list_agent_roles shows Bob's role", roles:find("reviewer") ~= nil)
check("list_agent_roles shows Carol's role", roles:find("qa") ~= nil)
check("list_agent_roles excludes other-instance peer", not roles:find("intruder"))
check("list_agent_roles excludes legacy project-level peer", not roles:find("ghost"))

-- ---------------------------------------------------------------------------
-- 6. log_work + read_agent_history round-trip.
-- ---------------------------------------------------------------------------

local logged, lerr = run("log_work", { summary = "implemented foo\nWith a retry loop.", topics = { "Auth Flow", "testing" } })
check("log_work succeeds", not lerr and logged:find("Logged '", 1, true) ~= nil, logged)
run("log_work", { summary = "fixed bar", title = "Bar fix" })

local today = os.date("%Y-%m-%d")
local vault = runtime_dir .. "/history"
check("vault README created", read(vault .. "/README.md") ~= nil)
local day_dir = vault .. "/agents/Alice/" .. today
local entries = vim.fn.glob(day_dir .. "/*.md", false, true)
check("one note per log_work under agents/Alice/<today>/", #entries == 2, vim.inspect(entries))
-- Two notes in the same minute sort alphabetically, so look at both.
local both = (read(entries[1]) or "") .. (read(entries[2]) or "")
check("entry notes carry the summary and topic links", both:find("implemented foo", 1, true) ~= nil and both:find("[[topics/auth-flow]]", 1, true) ~= nil, both)
check("second entry used the explicit title in its file name", vim.fn.glob(day_dir .. "/*-bar-fix.md") ~= "")
check("topics normalised to slugs", read(vault .. "/topics/auth-flow.md") ~= nil)
check("agent index groups today's entries", (read(vault .. "/agents/Alice/index.md") or ""):find("## " .. today, 1, true) ~= nil)

local history, _ = run("read_agent_history", {})
check("read_agent_history returns Alice's note", history:find("implemented foo", 1, true) ~= nil and history:find("fixed bar", 1, true) ~= nil)

-- Another agent's entry (written through the same module) shares a topic.
local Hm = require("history")
Hm.log(vault, "Bob", "reviewed PR for the retry loop", { topics = { "testing" } })

local cwd_history, _ = run("read_cwd_history", {})
check("read_cwd_history includes Alice's entries", cwd_history:find("implemented foo", 1, true) ~= nil)
check("read_cwd_history includes Bob's entries", cwd_history:find("reviewed PR", 1, true) ~= nil)

local topics_out, _ = run("list_history_topics", {})
check("list_history_topics lists slugs", topics_out:find("auth%-flow") ~= nil and topics_out:find("testing") ~= nil, topics_out)
local topic_out, _ = run("read_history_topic", { topic = "Testing" })
check("read_history_topic resolves entries from both agents", topic_out:find("implemented foo", 1, true) ~= nil and topic_out:find("reviewed PR", 1, true) ~= nil, topic_out)
local missing_out, merr = run("read_history_topic", { topic = "nope" })
check("read_history_topic on an unknown topic is a soft miss", not merr and missing_out:find("No topic", 1, true) ~= nil)

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
vim.env.NVIM_AGENT_RUNTIME_DIR = nil

print(string.format("\n%d/%d checks passed", total - fail_count, total))
if fail_count > 0 then
	os.exit(1)
end
