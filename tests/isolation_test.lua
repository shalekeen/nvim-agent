-- Cross-instance isolation test: two REAL Neovim processes in the same cwd,
-- with the SAME named workspace live (hence the same session names), must
-- share nothing an agent can read — only the workspace configuration.
-- Run with: nvim -l tests/isolation_test.lua
--
-- This process is instance A. It launches workspace "team" first, then
-- starts a second `nvim -l` (instance B) that launches the same workspace,
-- plants distinctively marked status / mailbox / history content in ITS
-- instance tree, adds a member to the manifest, and reports the environment
-- its CLI process received. A then plants its own markers, adds a member
-- using its (now stale) in-memory manifest, and asserts:
--   * both CLI processes were handed their own, distinct RUNTIME_DIR,
--     INSTANCE_ID, PROCESS_DIR and ACTIVE_DIR (read from /proc)
--   * the real hook script, run with A's environment, injects A's markers
--     and none of B's
--   * nothing of B's exists under A's trees or at the shared project level
--   * the shared manifest ends up with BOTH instances' additions (no
--     last-writer-wins clobber)
--   * the agent-side MCP code refuses to run without NVIM_AGENT_NVIM_ADDR
--     (no fallback to a socket that might belong to another Neovim)

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if ROOT == "" or ROOT == "tests" then
	ROOT = "."
end
ROOT = vim.fn.fnamemodify(ROOT, ":p"):gsub("/$", "")
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(ROOT)
package.preload["which-key"] = function()
	return { add = function() end }
end
package.preload["barbar"] = function()
	return {}
end
package.preload["barbar.state"] = function()
	return nil
end
package.preload["barbar.ui.render"] = function()
	return nil
end

local fails, total = 0, 0
local function check(label, ok, detail)
	total = total + 1
	print((ok and "PASS " or "FAIL ") .. label .. (ok and "" or (" — " .. tostring(detail))))
	if not ok then
		fails = fails + 1
	end
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
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local sandbox = vim.fn.tempname()
local cwd = sandbox .. "/proj"
local base = sandbox .. "/base"
vim.fn.mkdir(cwd, "p")

-- ---------------------------------------------------------------------------
-- Shared per-instance body. Returns helpers; used by B as a separate process
-- and by A in-process. Phase 1 launches workspace "team" and plants marked
-- peer state; phase 2 adds a member via the in-memory manifest.
-- ---------------------------------------------------------------------------

local body = [==[
local ROOT, SANDBOX, MARK = ...
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:append(ROOT)
package.preload["which-key"] = function() return { add = function() end } end
package.preload["barbar"] = function() return {} end
package.preload["barbar.state"] = function() return nil end
package.preload["barbar.ui.render"] = function() return nil end

local cwd = SANDBOX .. "/proj"
vim.cmd("cd " .. vim.fn.fnameescape(cwd))
require("nvim-agent").setup({
	adapter = { get_cmd = function() return { "sh", "-c", "sleep 30" } end },
	base_dir = SANDBOX .. "/base",
	auto_open = false,
})
local L, S, W, A = require("nvim-agent.launcher"), require("nvim-agent.session"), require("nvim-agent.workspace"), require("nvim-agent.agent")

-- Shared library + shared manifest: created by whichever instance is first.
if not A.exists("engineer") then assert(A.create("engineer", { role = "shared_role" })) end
if not A.exists("qa") then assert(A.create("qa", { role = "qa_role" })) end
if not W.exists("team", cwd) then
	local m = W.new_manifest("team")
	W.save(m, cwd)
	assert(W.add_entry(m, { agent = "engineer" }, cwd))
end

local info = {}

function info.launch_and_plant()
	L.launch(W.read("team", cwd), cwd)
	vim.wait(3000, function() local s = S.get_by_name("engineer"); return s and s.jobid end)
	local sess = S.get_by_name("engineer")
	assert(sess and sess.jobid, "engineer did not launch")
	local inst = W.instance_runtime_dir(cwd)

	local function put(p, c) vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p"); local f = assert(io.open(p, "w")); f:write(c); f:close() end
	put(inst .. "/messages/engineer.md", "MSG_" .. MARK .. "\n")
	put(inst .. "/history/agents/engineer/" .. os.date("%Y-%m-%d") .. "/10-00-hist.md", "HIST_" .. MARK .. "\n")
	put(inst .. "/status/peer-" .. MARK .. ".json", '{"agent":"peer-' .. MARK .. '","role":"ROLE_' .. MARK .. '","current_task":"TASK_' .. MARK .. '","updated_at":"x"}')
	put(sess.process_dir .. "/tmux_captures.json", '{"captures":[{"content":"TMUX_' .. MARK .. '"}]}')
	-- A workspace override made from this instance is workspace config and
	-- IS shared with the other instance (by design) — but only on relaunch.
	put(sess.active_dir .. "/user_notes.md", "NOTES_" .. MARK .. "\n")
	L.sync_session_file(sess, "user_notes.md", true)

	-- Environment the CLI process actually received. Poll: right after
	-- termopen the child may still be between fork and exec.
	local env = {}
	local pid = vim.fn.jobpid(sess.jobid)
	vim.wait(3000, function()
		local f = io.open("/proc/" .. pid .. "/environ", "rb")
		if not f then return false end
		local raw = f:read("*a"); f:close()
		local found = {}
		for kv in raw:gmatch("[^%z]+") do
			local k, v = kv:match("^([^=]+)=(.*)$")
			if k and k:match("^NVIM_AGENT_") then found[k] = v end
		end
		if next(found) then env = found; return true end
		return false
	end, 50)

	info.instance_id = S.instance_id
	info.runtime_dir = inst
	info.process_dir = sess.process_dir
	info.active_dir = sess.active_dir
	info.env = env
	info.workspace = W.get_current().name
end

function info.add_member()
	-- Uses the in-memory manifest held since launch — stale if the other
	-- instance has written since.
	L.add_agent("qa", "qa-" .. MARK, cwd)
	vim.wait(3000, function() local s = S.get_by_name("qa-" .. MARK); return s and s.jobid end)
	info.added = S.get_by_name("qa-" .. MARK) ~= nil
end

function info.close_all()
	for _, s in ipairs(S.list()) do S.close(s.id) end
end

return info
]==]

-- ---------------------------------------------------------------------------
-- Instance A (this process): launch the shared workspace first.
-- ---------------------------------------------------------------------------

local A = assert(loadstring(body, "instance_a"))(ROOT, sandbox, "A")
A.launch_and_plant()
check("instance A launched workspace 'team'", A.workspace == "team" and A.instance_id ~= nil)

-- ---------------------------------------------------------------------------
-- Instance B: a separate nvim process, same cwd, same workspace. It plants
-- its markers AND adds a member, so A's in-memory manifest goes stale.
-- ---------------------------------------------------------------------------

local b_script = sandbox .. "/instance_b.lua"
-- `nvim -l script a b c` exposes its arguments as the global `arg`, not `...`.
write(b_script, "local run = function(...)\n" .. body .. "\nend\nlocal info = run(arg[1], arg[2], arg[3])\ninfo.launch_and_plant()\ninfo.add_member()\ninfo.close_all()\nfor k, v in pairs(info) do if type(v) == 'function' then info[k] = nil end end\nprint(vim.json.encode(info))\n")
local b_out = vim.fn.system({ "nvim", "-l", b_script, ROOT, sandbox, "B" })
local b_json = b_out:match("(%b{})%s*$")
check("instance B ran and launched the same workspace", b_json ~= nil, b_out)
local B = b_json and vim.json.decode(b_json) or { env = {} }
check("B added its member", B.added == true)

-- A now adds a member with its stale manifest.
A.add_member()
check("A added its member", A.added == true)

-- ---------------------------------------------------------------------------
-- 1. Identity: everything that scopes context differs between A and B.
-- ---------------------------------------------------------------------------

check("instance ids differ", A.instance_id ~= B.instance_id, A.instance_id)
check("runtime dirs differ", A.runtime_dir ~= B.runtime_dir)
check("process dirs differ", A.process_dir ~= B.process_dir)
check("active dirs differ (same session name 'engineer' in both)", A.active_dir ~= B.active_dir)
check("both runtime dirs live under <cwd>/.nvim-agent/instances/<own id>",
	A.runtime_dir == cwd .. "/.nvim-agent/instances/" .. A.instance_id and B.runtime_dir == cwd .. "/.nvim-agent/instances/" .. B.instance_id)

-- ---------------------------------------------------------------------------
-- 2. The CLI processes were handed their own instance's paths (from /proc).
-- ---------------------------------------------------------------------------

local have_proc = next(A.env) ~= nil
check("/proc readable for A's CLI process", have_proc)
if have_proc then
	check("A's CLI got A's RUNTIME_DIR", A.env.NVIM_AGENT_RUNTIME_DIR == A.runtime_dir, A.env.NVIM_AGENT_RUNTIME_DIR)
	check("A's CLI got A's INSTANCE_ID", A.env.NVIM_AGENT_INSTANCE_ID == A.instance_id)
	check("A's CLI got A's PROCESS_DIR", A.env.NVIM_AGENT_PROCESS_DIR == A.process_dir)
	check("A's CLI got A's ACTIVE_DIR", A.env.NVIM_AGENT_ACTIVE_DIR == A.active_dir)
	check("A's CLI got the project cwd", A.env.NVIM_AGENT_CWD == cwd)
	check("B's CLI got B's RUNTIME_DIR", B.env.NVIM_AGENT_RUNTIME_DIR == B.runtime_dir, B.env.NVIM_AGENT_RUNTIME_DIR)
	check("B's CLI got B's INSTANCE_ID", B.env.NVIM_AGENT_INSTANCE_ID == B.instance_id)
	check("A and B CLI environments disagree on every instance-scoped var",
		A.env.NVIM_AGENT_RUNTIME_DIR ~= B.env.NVIM_AGENT_RUNTIME_DIR
		and A.env.NVIM_AGENT_PROCESS_DIR ~= B.env.NVIM_AGENT_PROCESS_DIR
		and A.env.NVIM_AGENT_ACTIVE_DIR ~= B.env.NVIM_AGENT_ACTIVE_DIR
		and A.env.NVIM_AGENT_INSTANCE_ID ~= B.env.NVIM_AGENT_INSTANCE_ID)
end

-- ---------------------------------------------------------------------------
-- 3. On-disk separation of RUNTIME state. (B's own status files are gone:
--    it closed its sessions before exiting, which removes them.)
-- ---------------------------------------------------------------------------

local function tree_contains(dir, needle)
	for _, p in ipairs(vim.fn.glob(dir .. "/**/*", false, true)) do
		if vim.fn.filereadable(p) == 1 and (read(p) or ""):find(needle, 1, true) then
			return p
		end
	end
	return nil
end
check("no B markers under A's runtime dir", tree_contains(A.runtime_dir, "_B") == nil, tree_contains(A.runtime_dir, "_B"))
check("no A markers under B's runtime dir", tree_contains(B.runtime_dir, "_A") == nil, tree_contains(B.runtime_dir, "_A"))
check("no B markers under A's process dir (ephemeral/tmux/active mirrors)", tree_contains(A.process_dir, "_B") == nil, tree_contains(A.process_dir, "_B"))
check("A's status files are in A's tree", read(A.runtime_dir .. "/status/engineer.json") ~= nil and read(A.runtime_dir .. "/status/qa-A.json") ~= nil)
check("A's tree has no qa-B status", read(A.runtime_dir .. "/status/qa-B.json") == nil)
check("nothing was written to the shared project level", vim.fn.isdirectory(cwd .. "/.nvim-agent/status") == 0 and vim.fn.isdirectory(cwd .. "/.nvim-agent/messages") == 0)

-- A's live mirror still has A's notes even though B wrote an override for
-- the same member: overrides are applied at launch, never pushed into a
-- running session.
check("A's running mirror was not altered by B's override write", read(A.active_dir .. "/user_notes.md") == "NOTES_A\n", read(A.active_dir .. "/user_notes.md"))

-- ---------------------------------------------------------------------------
-- 4. What IS shared is configuration, and it merges instead of clobbering.
-- ---------------------------------------------------------------------------

local W = require("nvim-agent.workspace")
local manifest = W.read("team", cwd)
local names = {}
for _, e in ipairs(manifest and manifest.agents or {}) do
	names[e.name] = true
end
check("shared manifest kept B's member after A wrote with a stale copy", names["qa-B"] == true, vim.inspect(manifest))
check("shared manifest kept A's member", names["qa-A"] == true)
check("shared manifest kept the original member", names["engineer"] == true)
-- The override is workspace config shared by both instances: last writer
-- wins, by design. B wrote after A, so the file holds B's notes — while A's
-- RUNNING mirror (checked above) still holds A's.
check("member override is shared workspace config (last writer: B)", read(cwd .. "/.nvim-agent/workspaces/team/engineer/user_notes.md") == "NOTES_B\n", read(cwd .. "/.nvim-agent/workspaces/team/engineer/user_notes.md"))

-- ---------------------------------------------------------------------------
-- 5. The real hook, run with A's environment, injects only A.
-- ---------------------------------------------------------------------------

local src = read(ROOT .. "/lua/nvim-agent/adapter/claude_code.lua") or ""
local hook = src:match("local function hook_script_content%(%).-return %[%[(.-)%]%]")
check("extracted hook script", hook ~= nil)
if hook then
	local hook_path = sandbox .. "/hook.sh"
	write(hook_path, hook)
	local cmd = string.format(
		"NVIM_AGENT_ACTIVE_DIR=%s NVIM_AGENT_PROCESS_DIR=%s NVIM_AGENT_CWD=%s NVIM_AGENT_RUNTIME_DIR=%s bash %s 2>&1",
		vim.fn.shellescape(A.active_dir), vim.fn.shellescape(A.process_dir), vim.fn.shellescape(cwd), vim.fn.shellescape(A.runtime_dir), vim.fn.shellescape(hook_path)
	)
	local out = vim.fn.system(cmd)
	check("hook: role from the shared library agent injected", out:find("shared_role", 1, true) ~= nil)
	check("hook: A's notes injected", out:find("NOTES_A", 1, true) ~= nil)
	check("hook: A's mailbox injected", out:find("MSG_A", 1, true) ~= nil)
	check("hook: A's history injected", out:find("HIST_A", 1, true) ~= nil)
	check("hook: A's peers injected (planted peer + qa-A)", out:find("peer-A", 1, true) ~= nil and out:find("Agent: qa-A", 1, true) ~= nil)
	check("hook: A's tmux captures injected", out:find("TMUX_A", 1, true) ~= nil)
	check("hook: no B notes", out:find("NOTES_B", 1, true) == nil)
	check("hook: no B mailbox", out:find("MSG_B", 1, true) == nil)
	check("hook: no B history", out:find("HIST_B", 1, true) == nil)
	check("hook: no B peers (planted peer or qa-B)", out:find("peer-B", 1, true) == nil and out:find("qa-B", 1, true) == nil)
	check("hook: no B tmux captures", out:find("TMUX_B", 1, true) == nil)
end

-- ---------------------------------------------------------------------------
-- 6. Agent-side MCP code fails closed without the parent's socket address,
--    even when $NVIM points at another Neovim's socket.
-- ---------------------------------------------------------------------------

local probe = sandbox .. "/rpc_probe.lua"
write(probe, [[
package.path = arg[1] .. "/lua/nvim-agent/mcp/?.lua;" .. package.path
local rpc = require("nvim_rpc")
local ok, err = rpc.list_buffers()
print(vim.json.encode({ ok = ok ~= nil, err = err }))
]])
-- `nvim -l` binds NVIM_LISTEN_ADDRESS itself, so the "foreign socket" is
-- offered via $NVIM (what a shell inside another Neovim's terminal carries).
local foreign = sandbox .. "/not-ours.sock"
local probe_out = vim.fn.system("env -u NVIM_AGENT_NVIM_ADDR -u NVIM_LISTEN_ADDRESS NVIM=" .. vim.fn.shellescape(foreign) .. " nvim -l " .. vim.fn.shellescape(probe) .. " " .. vim.fn.shellescape(ROOT) .. " 2>&1")
local probe_json = probe_out:match("(%b{})%s*$")
local P = probe_json and vim.json.decode(probe_json) or {}
check("RPC refuses to run without NVIM_AGENT_NVIM_ADDR (ignores $NVIM)", P.ok == false and tostring(P.err):find("NVIM_AGENT_NVIM_ADDR") ~= nil, probe_out)

local server_out = vim.fn.system("env -u NVIM_AGENT_NVIM_ADDR -u NVIM_LISTEN_ADDRESS NVIM=" .. vim.fn.shellescape(foreign) .. " nvim -l " .. vim.fn.shellescape(ROOT .. "/lua/nvim-agent/mcp/server.lua") .. " </dev/null 2>&1; echo EXIT=$?")
check("MCP server exits non-zero without NVIM_AGENT_NVIM_ADDR (ignores $NVIM)", server_out:find("EXIT=1") ~= nil and not server_out:find("Failed"), server_out)

-- ---------------------------------------------------------------------------
-- Cleanup + summary
-- ---------------------------------------------------------------------------

A.close_all()
vim.cmd("cd " .. vim.fn.fnameescape(ROOT))
vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fails, total))
if fails > 0 then
	os.exit(1)
end
