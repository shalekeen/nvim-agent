-- Work-history vault: an Obsidian-compatible folder of structured markdown.
--
-- Shared between the MCP server (flat require("history") under `nvim -l`)
-- and the parent Neovim (require("nvim-agent.mcp.history")). Pure file I/O.
-- One vault per Neovim instance, shared by every agent in it.
--
--   <runtime_dir>/history/                      ← open this folder in Obsidian
--     README.md                                 what the vault is, how it is laid out
--     agents/<agent>/index.md                   that agent's entries, grouped by day
--     agents/<agent>/YYYY-MM-DD/                subdir per day
--       HH-MM-<title-slug>.md                   ONE NOTE PER log_work CALL
--     topics/<topic>.md                         per-topic note linking every entry
--                                               tagged with it, across agents and days
--
-- Links are Obsidian wikilinks relative to the vault root, e.g.
--   [[agents/engineer/2026-11-09/14-05-added-retry-to-fetch|…]]
-- so the graph view connects agents' days through shared topics. `agents/`
-- wraps the per-agent dirs so an agent named "topics" cannot collide with
-- the vault's own folders.

local M = {}

M.DATE_FMT = "%Y-%m-%d"
M.TIME_FMT = "%H:%M"

------------------------------------------------------------------------
-- File helpers
------------------------------------------------------------------------

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
	if not f then
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function append(path, text)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "a")
	if not f then
		return false
	end
	f:write(text)
	f:close()
	return true
end

local function exists(path)
	return vim.fn.filereadable(path) == 1
end

local function list_dirs(path)
	if vim.fn.isdirectory(path) ~= 1 then
		return {}
	end
	local out = {}
	for _, e in ipairs(vim.fn.readdir(path)) do
		if vim.fn.isdirectory(path .. "/" .. e) == 1 and not e:match("^%.") then
			table.insert(out, e)
		end
	end
	table.sort(out)
	return out
end

local function list_md(path)
	if vim.fn.isdirectory(path) ~= 1 then
		return {}
	end
	local out = {}
	for _, e in ipairs(vim.fn.readdir(path)) do
		local name = e:match("^(.+)%.md$")
		if name and not name:match("^%.") then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function escape_pattern(s)
	return (s:gsub("%p", "%%%0"))
end

------------------------------------------------------------------------
-- Naming
------------------------------------------------------------------------

--- Topic / title slugs: lowercase kebab-case, ASCII word chars.
--- @param text string
--- @return string|nil
function M.slug(text)
	if type(text) ~= "string" then
		return nil
	end
	local s = text:lower():gsub("[%s_]+", "-"):gsub("[^%w%-]", ""):gsub("%-%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
	if s == "" then
		return nil
	end
	return s
end

function M.vault_dir(runtime_dir)
	return runtime_dir .. "/history"
end

function M.agent_dir(vault, agent)
	return vault .. "/agents/" .. agent
end

function M.agent_index(vault, agent)
	return M.agent_dir(vault, agent) .. "/index.md"
end

function M.day_dir(vault, agent, date)
	return M.agent_dir(vault, agent) .. "/" .. date
end

function M.topic_note(vault, topic)
	return vault .. "/topics/" .. M.slug(topic) .. ".md"
end

--- @param now number|nil  os.time() value; default now
function M.today(now)
	return os.date(M.DATE_FMT, now)
end

------------------------------------------------------------------------
-- Vault bootstrap
------------------------------------------------------------------------

local README = [[# Work history

This folder is an Obsidian vault written by nvim-agent. Open it in Obsidian to
browse it; agents write to it through the `log_work` MCP tool, never by hand.

- `agents/<agent>/YYYY-MM-DD/HH-MM-<title>.md` — one note per unit of work,
  filed under the agent and the day it was logged. Each carries the agent,
  time, title, topics and the summary.
- `agents/<agent>/index.md` — that agent's entries grouped by day.
- `topics/<topic>.md` — one note per topic, linking every entry tagged with
  it across agents and days. Topics are how threads of work connect.
]]

--- Create README.md if missing. Cheap; safe to call on every write.
function M.ensure_vault(vault)
	if not exists(vault .. "/README.md") then
		write(vault .. "/README.md", README)
	end
end

------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------

local function first_line(s)
	local l = s:match("^%s*([^\n]*)") or ""
	l = trim(l:gsub("^#+%s*", ""))
	if #l > 72 then
		l = l:sub(1, 71) .. "…"
	end
	return l ~= "" and l or "entry"
end

--- Normalise a topics argument (array of strings) into unique slugs.
--- @return string[]
function M.normalize_topics(topics)
	local out, seen = {}, {}
	if type(topics) == "table" then
		for _, t in ipairs(topics) do
			local s = M.slug(t)
			if s and not seen[s] then
				seen[s] = true
				table.insert(out, s)
			end
		end
	end
	return out
end

--- Record one unit of work for `agent` as its own note.
--- @param vault string
--- @param agent string
--- @param summary string
--- @param opts table|nil  { title = string, topics = string[], now = number }
--- @return table  { path, link, date, time, title, topics }
function M.log(vault, agent, summary, opts)
	opts = opts or {}
	local now = opts.now or os.time()
	local date = os.date(M.DATE_FMT, now)
	local time = os.date(M.TIME_FMT, now)
	local title = (type(opts.title) == "string" and not opts.title:match("^%s*$")) and trim(opts.title) or first_line(summary)
	local topics = M.normalize_topics(opts.topics)

	M.ensure_vault(vault)

	-- Entry note: HH-MM-<slug>.md, disambiguated if logged twice in a minute.
	local day_dir = M.day_dir(vault, agent, date)
	local base = time:gsub(":", "-") .. "-" .. (M.slug(title) or "entry"):sub(1, 60)
	local name = base
	local n = 2
	while exists(day_dir .. "/" .. name .. ".md") do
		name = base .. "-" .. n
		n = n + 1
	end
	local path = day_dir .. "/" .. name .. ".md"
	local link = string.format("agents/%s/%s/%s", agent, date, name)

	local topic_links = {}
	for _, t in ipairs(topics) do
		table.insert(topic_links, "[[topics/" .. t .. "]]")
	end
	local fm_topics = #topics > 0 and ("[" .. table.concat(topics, ", ") .. "]") or "[]"
	write(
		path,
		string.format(
			"---\nagent: %s\ndate: %s\ntime: \"%s\"\ntopics: %s\n---\n# %s\n**Agent:** [[agents/%s/index|%s]] · **Day:** %s%s\n\n%s\n",
			agent,
			date,
			time,
			fm_topics,
			title,
			agent,
			agent,
			date,
			#topic_links > 0 and (" · **Topics:** " .. table.concat(topic_links, " ")) or "",
			trim(summary)
		)
	)

	-- Agent index: a "## <date>" heading once per day, then one bullet per entry.
	local index = M.agent_index(vault, agent)
	if not exists(index) then
		write(index, string.format("# %s\n\nWork log, oldest first.\n", agent))
	end
	local idx = read(index) or ""
	if not idx:find("\n## " .. date .. "\n", 1, true) then
		append(index, "\n## " .. date .. "\n")
	end
	append(index, string.format("- [[%s|%s %s]]\n", link, time, title))

	-- Topic notes: one bullet per entry.
	for _, t in ipairs(topics) do
		local tnote = M.topic_note(vault, t)
		if not exists(tnote) then
			write(tnote, string.format("# %s\n\nEntries, oldest first.\n\n", t))
		end
		append(tnote, string.format("- [[%s|%s %s %s: %s]]\n", link, date, time, agent, title))
	end

	return { path = path, link = link, date = date, time = time, title = title, topics = topics }
end

------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------

--- Agents that have a directory in the vault.
--- @return string[]
function M.list_agents(vault)
	return list_dirs(vault .. "/agents")
end

--- Dates an agent has entries for, newest first, optionally only the last N.
--- @return string[]
function M.agent_dates(vault, agent, days)
	local all = list_dirs(M.agent_dir(vault, agent))
	table.sort(all, function(a, b)
		return a > b
	end)
	if days and days > 0 and #all > days then
		local cut = {}
		for i = 1, days do
			cut[i] = all[i]
		end
		return cut
	end
	return all
end

--- All dates present across agents, newest first, optionally the last N.
--- @return string[]
function M.dates(vault, days)
	local seen, all = {}, {}
	for _, agent in ipairs(M.list_agents(vault)) do
		for _, d in ipairs(list_dirs(M.agent_dir(vault, agent))) do
			if not seen[d] then
				seen[d] = true
				table.insert(all, d)
			end
		end
	end
	table.sort(all, function(a, b)
		return a > b
	end)
	if days and days > 0 and #all > days then
		local cut = {}
		for i = 1, days do
			cut[i] = all[i]
		end
		return cut
	end
	return all
end

--- The entry notes of one agent-day, concatenated in time order.
local function read_day(vault, agent, date)
	local dir = M.day_dir(vault, agent, date)
	local parts = {}
	for _, name in ipairs(list_md(dir)) do
		local c = read(dir .. "/" .. name .. ".md")
		if c and not c:match("^%s*$") then
			table.insert(parts, c)
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--- One agent's entries, newest day first (entries chronological within a day).
--- @param days integer|nil  nil → all
--- @return string|nil  nil when the agent has no entries
function M.read_agent(vault, agent, days)
	local parts = {}
	for _, date in ipairs(M.agent_dates(vault, agent, days)) do
		local c = read_day(vault, agent, date)
		if c then
			table.insert(parts, c)
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--- Every agent's entries for the last `days` days (default 3), newest day
--- first, agents alphabetical within a day.
--- @return string|nil
function M.read_all(vault, days)
	local parts = {}
	local agents = M.list_agents(vault)
	for _, date in ipairs(M.dates(vault, days or 3)) do
		for _, agent in ipairs(agents) do
			local c = read_day(vault, agent, date)
			if c then
				table.insert(parts, c)
			end
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--- Topic names in the vault.
--- @return string[]
function M.list_topics(vault)
	return list_md(vault .. "/topics")
end

--- A topic note plus every entry it links to, in full.
--- @return string|nil
function M.read_topic(vault, topic)
	local slug = M.slug(topic)
	if not slug then
		return nil
	end
	local note = read(M.topic_note(vault, slug))
	if not note then
		return nil
	end
	local out = { note, "---", "" }
	for link in note:gmatch("%[%[(agents/[^|%]]+)") do
		local c = read(vault .. "/" .. link .. ".md")
		if c then
			table.insert(out, c)
		end
	end
	return table.concat(out, "\n")
end

------------------------------------------------------------------------
-- Forgetting (config.json: history = "fresh")
------------------------------------------------------------------------

--- Remove every trace of `agent` from the vault: its directory (all days,
--- all entries, its index) and its lines in topic notes. Topic notes left
--- with no entries are removed too.
function M.forget_agent(vault, agent)
	local dir = M.agent_dir(vault, agent)
	if vim.fn.isdirectory(dir) == 1 then
		vim.fn.delete(dir, "rf")
	end
	local marker = "%[%[agents/" .. escape_pattern(agent) .. "/"
	for _, t in ipairs(M.list_topics(vault)) do
		local tnote = M.topic_note(vault, t)
		local c = read(tnote)
		if c then
			local kept, removed, entries = {}, false, 0
			for line in (c .. "\n"):gmatch("([^\n]*)\n") do
				if line:match("^%- " .. marker) then
					removed = true
				else
					table.insert(kept, line)
					if line:match("^%- %[%[agents/") then
						entries = entries + 1
					end
				end
			end
			if removed then
				if entries == 0 then
					vim.fn.delete(tnote)
				else
					write(tnote, table.concat(kept, "\n"))
				end
			end
		end
	end
end

return M
