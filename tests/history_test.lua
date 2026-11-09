-- Work-history vault tests (lua/nvim-agent/mcp/history.lua).
-- Run with: nvim -l tests/history_test.lua
--
-- The vault is an Obsidian-compatible folder shared by every agent in an
-- instance: agents/<agent>/<date>/HH-MM-<title>.md, one note per log_work
-- call, an agents/<agent>/index.md grouped by day, and topics/<topic>.md
-- notes linking entries across agents and days.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = (script_dir:gsub("/$", "")):gsub("/tests$", "")
if ROOT == "" or ROOT == "tests" then
	ROOT = "."
end
package.path = ROOT .. "/lua/?.lua;" .. ROOT .. "/lua/?/init.lua;" .. package.path

local H = require("nvim-agent.mcp.history")

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

local sandbox = vim.fn.tempname()
local vault = H.vault_dir(sandbox .. "/instance")

-- Deterministic clock.
local day1 = os.time({ year = 2026, month = 11, day = 8, hour = 14, min = 5 })
local day1_later = os.time({ year = 2026, month = 11, day = 8, hour = 16, min = 30 })
local day2 = os.time({ year = 2026, month = 11, day = 9, hour = 9, min = 0 })
local D1, D2 = "2026-11-08", "2026-11-09"

-- ---------------------------------------------------------------------------
-- 1. slug / topic normalisation
-- ---------------------------------------------------------------------------

check("slug lowercases and kebab-cases", H.slug("Auth Flow") == "auth-flow")
check("slug strips punctuation and collapses dashes", H.slug("  MCP -- server!! ") == "mcp-server")
check("slug of junk is nil", H.slug("!!!") == nil and H.slug(42) == nil)
local norm = H.normalize_topics({ "Auth", "auth", "Testing", "", 7, "x_y" })
check("normalize_topics dedupes and drops junk", #norm == 3 and norm[1] == "auth" and norm[2] == "testing" and norm[3] == "x-y", vim.inspect(norm))

-- ---------------------------------------------------------------------------
-- 2. log: layout agents/<agent>/<date>/HH-MM-<slug>.md, frontmatter, links
-- ---------------------------------------------------------------------------

local r1 = H.log(vault, "engineer", "Added retry to fetch\nThree attempts with backoff.", { topics = { "Networking", "resilience" }, now = day1 })
check("README created", read(vault .. "/README.md") ~= nil)
check("entry path is agents/<agent>/<date>/HH-MM-<title-slug>.md", r1.path == vault .. "/agents/engineer/" .. D1 .. "/14-05-added-retry-to-fetch.md", r1.path)
check("link is vault-relative without .md", r1.link == "agents/engineer/" .. D1 .. "/14-05-added-retry-to-fetch")
local note = read(r1.path) or ""
check("entry has frontmatter with agent/date/time/topics", note:sub(1, 200):find('---\nagent: engineer\ndate: ' .. D1 .. '\ntime: "14:05"\ntopics: [networking, resilience]\n---\n', 1, true) == 1, note)
check("entry title is the first line of the summary", note:find("\n# Added retry to fetch\n", 1, true) ~= nil)
check("entry meta links agent index + topics", note:find("**Agent:** [[agents/engineer/index|engineer]] · **Day:** " .. D1 .. " · **Topics:** [[topics/networking]] [[topics/resilience]]", 1, true) ~= nil, note)
check("entry body is the summary", note:find("Three attempts with backoff.", 1, true) ~= nil)

local idx = read(H.agent_index(vault, "engineer")) or ""
check("agent index has a day heading and the entry", idx:find("\n## " .. D1 .. "\n", 1, true) ~= nil and idx:find("- [[" .. r1.link .. "|14:05 Added retry to fetch]]", 1, true) ~= nil, idx)
local tnet = read(H.topic_note(vault, "networking")) or ""
check("topic note links the entry", tnet:find("- [[" .. r1.link .. "|" .. D1 .. " 14:05 engineer: Added retry to fetch]]", 1, true) ~= nil, tnet)

-- Second entry, same day: new file, index day heading not duplicated.
local r2 = H.log(vault, "engineer", "Wrote tests for the retry path.", { title = "Retry tests", topics = { "resilience", "testing" }, now = day1_later })
check("second entry is its own note", r2.path ~= r1.path and read(r2.path) ~= nil and r2.title == "Retry tests")
idx = read(H.agent_index(vault, "engineer")) or ""
-- Dates contain '-', a pattern quantifier: escape before gsub-counting.
local D1p = D1:gsub("%-", "%%-")
check("index lists the day heading once with two entries", select(2, idx:gsub("\n## " .. D1p .. "\n", "")) == 1 and select(2, idx:gsub("%- %[%[agents/", "")) == 2, idx)
local tres = read(H.topic_note(vault, "resilience")) or ""
check("topic note accumulates entries across the day", select(2, tres:gsub("%- %[%[agents/", "")) == 2)

-- Same minute twice: file name disambiguated.
local r_dup = H.log(vault, "engineer", "Added retry to fetch", { now = day1 })
check("same title in the same minute gets a -2 suffix", r_dup.path:match("14%-05%-added%-retry%-to%-fetch%-2%.md$") ~= nil, r_dup.path)

-- Different agent, next day, shared topic.
H.log(vault, "qa", "Verified retry under packet loss.", { topics = { "resilience" }, now = day2 })
tres = read(H.topic_note(vault, "resilience")) or ""
check("topic links entries across agents AND days", tres:find("agents/qa/" .. D2 .. "/09-00-", 1, true) ~= nil and select(2, tres:gsub("%- %[%[agents/", "")) == 3)
H.log(vault, "engineer", "Day two: refactor.", { now = day2 })
check("entry with no topics has topics: [] and no Topics field", (function()
	local c = read(vault .. "/agents/engineer/" .. D2 .. "/09-00-day-two-refactor.md") or ""
	return c:find("topics: []", 1, true) ~= nil and c:find("**Topics:**", 1, true) == nil
end)())
local r3 = H.log(vault, "qa", "   ", { now = day2 })
check("blank summary falls back to title 'entry'", r3.title == "entry")

-- ---------------------------------------------------------------------------
-- 3. Reading
-- ---------------------------------------------------------------------------

check("list_agents", table.concat(H.list_agents(vault), ",") == "engineer,qa")
local dates = H.dates(vault)
check("dates newest first", #dates == 2 and dates[1] == D2 and dates[2] == D1, vim.inspect(dates))
check("agent_dates with a limit", #H.agent_dates(vault, "engineer", 1) == 1 and H.agent_dates(vault, "engineer", 1)[1] == D2)

local eng = H.read_agent(vault, "engineer") or ""
check("read_agent returns both days, newest first", eng:find("Day two: refactor", 1, true) < eng:find("Added retry to fetch", 1, true))
check("read_agent orders entries chronologically within a day", eng:find("Added retry to fetch", 1, true) < eng:find("Retry tests", 1, true))
check("read_agent with days=1 returns only the newest day", (H.read_agent(vault, "engineer", 1) or ""):find("Added retry", 1, true) == nil)
check("read_agent for unknown agent is nil", H.read_agent(vault, "nobody") == nil)

local all = H.read_all(vault) or ""
check("read_all includes every agent and day (default 3 days)", all:find("Verified retry", 1, true) ~= nil and all:find("Added retry", 1, true) ~= nil)
check("read_all with days=1 excludes day one", (H.read_all(vault, 1) or ""):find("Added retry", 1, true) == nil)

local topics = H.list_topics(vault)
check("list_topics sorted slugs", table.concat(topics, ",") == "networking,resilience,testing", vim.inspect(topics))

local rt = H.read_topic(vault, "Resilience") or ""
check("read_topic returns the topic note plus every linked entry in full",
	rt:find("# resilience", 1, true) ~= nil
		and rt:find("Three attempts with backoff.", 1, true) ~= nil
		and rt:find("Wrote tests for the retry path.", 1, true) ~= nil
		and rt:find("Verified retry under packet loss.", 1, true) ~= nil,
	rt)
check("read_topic unknown → nil", H.read_topic(vault, "nope") == nil)

-- ---------------------------------------------------------------------------
-- 3b. Instance attribution and instance-scoped forgetting: the vault is
--     shared by every Neovim running the workspace.
-- ---------------------------------------------------------------------------

local vault2 = H.vault_dir(sandbox .. "/ws")
local ra = H.log(vault2, "engineer", "from window A", { topics = { "shared" }, now = day1, instance = "aaaaaaaa-0000-4000-8000-000000000001" })
local rb = H.log(vault2, "engineer", "from window B", { topics = { "shared" }, now = day1_later, instance = "bbbbbbbb-0000-4000-8000-000000000002" })
local ra_note = read(ra.path) or ""
check("entry frontmatter records the writing instance", ra_note:find("\ninstance: aaaaaaaa-0000-4000-8000-000000000001\n", 1, true) ~= nil, ra_note)
check("entry body shows the short instance id", ra_note:find("**Instance:** aaaaaaaa", 1, true) ~= nil)
check("index and topic lines carry the short instance id", (read(H.agent_index(vault2, "engineer")) or ""):find("· aaaaaaaa", 1, true) ~= nil and (read(H.topic_note(vault2, "shared")) or ""):find("· bbbbbbbb", 1, true) ~= nil)
check("entry without instance has no instance field", (read(r1.path) or ""):find("instance:", 1, true) == nil)

H.forget_agent(vault2, "engineer", "aaaaaaaa-0000-4000-8000-000000000001")
check("scoped forget removes only that instance's entry", read(ra.path) == nil and read(rb.path) ~= nil)
local idx2 = read(H.agent_index(vault2, "engineer")) or ""
check("scoped forget drops the removed entry from the index, keeps the other", idx2:find("from-window-a", 1, true) == nil and idx2:find("from-window-b", 1, true) ~= nil, idx2)
local tsh = read(H.topic_note(vault2, "shared")) or ""
check("scoped forget drops the removed entry from topics, keeps the other", tsh:find("from-window-a", 1, true) == nil and tsh:find("from-window-b", 1, true) ~= nil, tsh)
H.forget_agent(vault2, "engineer", "bbbbbbbb-0000-4000-8000-000000000002")
check("forgetting the last instance's entries removes index, topic and agent dir", read(H.agent_index(vault2, "engineer")) == nil and read(H.topic_note(vault2, "shared")) == nil and vim.fn.isdirectory(H.agent_dir(vault2, "engineer")) == 0)
check("scoped forget for an unknown instance is a no-op", (function()
	H.log(vault2, "qa", "x", { now = day2, instance = "cccccccc-0000-4000-8000-000000000003" })
	H.forget_agent(vault2, "qa", "dddddddd-0000-4000-8000-000000000004")
	return H.read_agent(vault2, "qa") ~= nil
end)())

-- ---------------------------------------------------------------------------
-- 4. forget_agent without an instance (removes everything)
-- ---------------------------------------------------------------------------

H.forget_agent(vault, "engineer")
check("forget removes the agent's directory (days, entries, index)", vim.fn.isdirectory(H.agent_dir(vault, "engineer")) == 0)
check("forget leaves other agents intact", read(vault .. "/agents/qa/" .. D2 .. "/09-00-verified-retry-under-packet-loss.md") ~= nil)
check("forget deletes topics only the agent used", read(H.topic_note(vault, "networking")) == nil and read(H.topic_note(vault, "testing")) == nil)
tres = read(H.topic_note(vault, "resilience")) or ""
check("forget strips the agent's lines from shared topics, keeps others", tres:find("agents/engineer/", 1, true) == nil and tres:find("agents/qa/", 1, true) ~= nil, tres)
check("forget of an unknown agent is a no-op", (function()
	H.forget_agent(vault, "ghost")
	return read(H.topic_note(vault, "resilience")) ~= nil
end)())

vim.fn.delete(sandbox, "rf")
print(string.format("\n%d/%d checks passed", total - fails, total))
if fails > 0 then
	os.exit(1)
end
