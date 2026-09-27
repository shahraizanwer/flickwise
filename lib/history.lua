-- history.lua — local fix history + personal mistake tracker (IDEAS 2.4)
-- Every fix (and every "show" answer) is appended to data/history.jsonl on this
-- Mac only: the directory is git-ignored and nothing is sent anywhere. Entries
-- older than `retention_days` are pruned on load. For modes listed in
-- `mistake_modes`, the word diff is turned into mistakes ({from, to, cat}) at
-- record time, and stats() aggregates them for the Progress tab.
-- Public API:
--   M.configure(settings)             features.history table
--   M.record(entry) -> id | nil       { mode, output, app, original, result }
--   M.mark_undone(id)                 an undone fix doesn't count as mistakes
--   M.last_id()
--   M.entries()                       newest first
--   M.get(id)
--   M.delete(id), M.clear()
--   M.stats()                         see the bottom of this file

local M = {}

local word_diff = require("flickwise.lib.word_diff")

local DATA_DIR  = os.getenv("HOME") .. "/.hammerspoon/flickwise/data"
local FILE      = DATA_DIR .. "/history.jsonl"
local MAX_ENTRIES = 5000
local DAY, WEEK = 86400, 7 * 86400

local _settings = nil
local _entries  = nil    -- oldest first
local _last_id  = nil
local _seq      = 0

-- ── storage ───────────────────────────────────────────────────────────────────

local function ensure_dir()
    if not hs.fs.attributes(DATA_DIR) then hs.fs.mkdir(DATA_DIR) end
end

local function rewrite()
    ensure_dir()
    local f = io.open(FILE, "w")
    if not f then return end
    for _, e in ipairs(_entries) do f:write(hs.json.encode(e), "\n") end
    f:close()
end

local function load()
    if _entries then return end
    _entries = {}
    local f = io.open(FILE, "r")
    if not f then return end
    local cutoff = os.time() - (_settings and _settings.retention_days or 90) * DAY
    local dropped = 0
    for line in f:lines() do
        local ok, e = pcall(hs.json.decode, line)
        if ok and type(e) == "table" and e.id then
            if (e.ts or 0) >= cutoff then table.insert(_entries, e) else dropped = dropped + 1 end
        end
    end
    f:close()
    while #_entries > MAX_ENTRIES do table.remove(_entries, 1); dropped = dropped + 1 end
    if dropped > 0 then rewrite() end
end

local function find(id)
    load()
    for i, e in ipairs(_entries) do if e.id == id then return e, i end end
end

-- ── mistake extraction ────────────────────────────────────────────────────────

local ARTICLES = { a = true, an = true, the = true }
local AUX = { is = true, are = true, was = true, were = true, am = true, be = true, been = true,
              has = true, have = true, had = true, ["do"] = true, does = true, did = true,
              will = true, would = true, can = true, could = true }
local PREPS = { ["in"] = true, on = true, at = true, to = true, ["for"] = true, of = true, with = true,
                by = true, from = true, about = true, into = true, onto = true, over = true }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function words(s)
    local out = {}
    for w in s:lower():gmatch("[^%s]+") do table.insert(out, w) end
    return out
end
local function strip_punct(s) return (s:gsub("[%p]", "")) end

local function edit_distance(a, b)
    if math.abs(#a - #b) > 3 then return 99 end
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
    end
    return prev[#b]
end

-- Only one extra (or missing) word from `set` separates the two sides?
local function differs_by(set, fw, tw)
    local long, short = fw, tw
    if #tw > #fw then long, short = tw, fw end
    if #long ~= #short + 1 then return false end
    local seen = {}
    for _, w in ipairs(short) do seen[w] = (seen[w] or 0) + 1 end
    local extra
    for _, w in ipairs(long) do
        if seen[w] and seen[w] > 0 then seen[w] = seen[w] - 1
        elseif extra then return false
        else extra = w end
    end
    return extra ~= nil and set[extra] == true
end

local function classify(from, to)
    local f, t = from:lower(), to:lower()
    if f == t then return "Capitalization" end
    if (from:find("'") or to:find("'")) and strip_punct(f) == strip_punct(t) then return "Apostrophes" end
    if strip_punct(f) == strip_punct(t) then return "Punctuation" end
    local fw, tw = words(strip_punct(f)), words(strip_punct(t))
    if differs_by(ARTICLES, fw, tw) then return "Articles (a / an / the)" end
    if #fw == 1 and #tw == 1 then
        local a, b = fw[1], tw[1]
        if b == a .. "s" or b == a .. "es" or a == b .. "s" or a == b .. "es" then return "Singular / plural" end
        if AUX[a] and AUX[b] then return "Verb form (is/are, has/have…)" end
        if PREPS[a] and PREPS[b] then return "Prepositions (in/on/at…)" end
        if edit_distance(a, b) <= 2 then return "Spelling" end
    end
    if differs_by(AUX, fw, tw) then return "Verb form (is/are, has/have…)" end
    if differs_by(PREPS, fw, tw) then return "Prepositions (in/on/at…)" end
    if #fw > 6 or #tw > 6 then return "Rewording" end
    return "Word choice"
end
M.classify = classify

local function extract_mistakes(original, result)
    local segs = word_diff.diff(original, result)
    local out, i = {}, 1
    while i <= #segs do
        local s = segs[i]
        if s.op == "eq" then
            i = i + 1
        else
            local from, to = "", ""
            if s.op == "del" then
                from = s.text
                if segs[i + 1] and segs[i + 1].op == "ins" then to = segs[i + 1].text; i = i + 1 end
            else
                to = s.text
            end
            i = i + 1
            from, to = trim(from), trim(to)
            if from ~= "" or to ~= "" then
                table.insert(out, { from = from, to = to, cat = classify(from, to) })
            end
        end
    end
    return out
end

local function tracks(mode_name)
    local list = _settings and _settings.mistake_modes
    if type(list) ~= "table" then return false end
    for _, n in ipairs(list) do
        if tostring(n):lower() == tostring(mode_name):lower() then return true end
    end
    return false
end

local function excluded(app)
    local list = _settings and _settings.exclude_apps
    if not app or type(list) ~= "table" then return false end
    for _, n in ipairs(list) do if tostring(n):lower() == app:lower() then return true end end
    return false
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.configure(settings)
    _settings = settings
    _entries = nil          -- reload (and prune) with the new retention
end

function M.enabled()
    return _settings ~= nil and _settings.enabled == true
end

function M.record(e)
    if not M.enabled() or excluded(e.app) then return nil end
    if not e.original or e.original == "" or not e.result then return nil end
    load()
    _seq = _seq + 1
    local entry = {
        id       = string.format("%d-%d", os.time(), _seq),
        ts       = os.time(),
        mode     = e.mode,
        output   = e.output or "replace",
        app      = e.app,
        original = e.original,
        result   = e.result,
    }
    if entry.output == "replace" and tracks(e.mode) then
        entry.tracked  = true
        entry.mistakes = extract_mistakes(e.original, e.result)
    end
    table.insert(_entries, entry)
    ensure_dir()
    local f = io.open(FILE, "a")
    if f then f:write(hs.json.encode(entry), "\n"); f:close() end
    _last_id = entry.id
    return entry.id
end

function M.last_id() return _last_id end

function M.mark_undone(id)
    local e = id and find(id)
    if e then e.undone = true; rewrite() end
end

function M.entries()
    load()
    local out = {}
    for i = #_entries, 1, -1 do table.insert(out, _entries[i]) end
    return out
end

function M.get(id) return (find(id)) end

function M.delete(id)
    local _, i = find(id)
    if i then table.remove(_entries, i); rewrite() end
end

function M.clear()
    _entries = {}
    rewrite()
end

-- stats() -> {
--   this_week = { fixes, mistakes }, last_week = { fixes, mistakes },
--   categories = { { name, week, total } }   sorted by total
--   top = { { from, to, cat, count } }       most repeated corrections
--   weeks = { { label, fixes, mistakes } }   last 8 weeks, oldest first
--   tracked_modes = { ... }, retention_days
-- }
function M.stats()
    load()
    local now = os.time()
    local s = {
        this_week = { fixes = 0, mistakes = 0 }, last_week = { fixes = 0, mistakes = 0 },
        categories = {}, top = {}, weeks = {},
        tracked_modes = _settings and _settings.mistake_modes or {},
        retention_days = _settings and _settings.retention_days or 90,
    }
    local cats, pairs_ = {}, {}
    for w = 7, 0, -1 do
        table.insert(s.weeks, { label = os.date("%b %d", now - (w + 1) * WEEK + DAY), fixes = 0, mistakes = 0 })
    end
    for _, e in ipairs(_entries) do
        if e.tracked and not e.undone then
            local age = now - e.ts
            local n = #(e.mistakes or {})
            local bucket = (age < WEEK and s.this_week) or (age < 2 * WEEK and s.last_week) or nil
            if bucket then bucket.fixes = bucket.fixes + 1; bucket.mistakes = bucket.mistakes + n end
            local wk = math.floor(age / WEEK)
            if wk <= 7 then
                local row = s.weeks[8 - wk]
                row.fixes = row.fixes + 1; row.mistakes = row.mistakes + n
            end
            for _, m in ipairs(e.mistakes or {}) do
                local c = cats[m.cat] or { name = m.cat, week = 0, total = 0 }
                c.total = c.total + 1
                if age < WEEK then c.week = c.week + 1 end
                cats[m.cat] = c
                if m.cat ~= "Rewording" then
                    local key = m.from:lower() .. "\0" .. m.to:lower()
                    local p = pairs_[key] or { from = m.from, to = m.to, cat = m.cat, count = 0 }
                    p.count = p.count + 1
                    pairs_[key] = p
                end
            end
        end
    end
    for _, c in pairs(cats) do table.insert(s.categories, c) end
    table.sort(s.categories, function(a, b) return a.total > b.total end)
    for _, p in pairs(pairs_) do table.insert(s.top, p) end
    table.sort(s.top, function(a, b) return a.count > b.count end)
    while #s.top > 12 do table.remove(s.top) end
    return s
end

return M
