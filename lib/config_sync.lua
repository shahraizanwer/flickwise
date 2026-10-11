-- config_sync.lua — bring an existing config.yaml up to date with new default modes
-- config.yaml is never overwritten on update (it holds the API key and your own
-- modes), so new modes shipped in config.example.yaml would never reach existing
-- installs. At startup this:
--   • appends default modes that this Mac hasn't been offered before
--   • removes modes listed in RETIRED (once), e.g. ones deleted from the defaults
-- Progress is remembered in data/config_sync.json ("seen"/"retired"), so a mode you
-- delete on purpose isn't re-added, and a retired name you re-create isn't removed again.
-- config.yaml is backed up to config.yaml.backup.<date> before any change.
-- Public API: M.run(config_path, example_path[, state_path]) -> { added = {names}, removed = {names} }

local M = {}

local tinyyaml = require("flickwise.lib.tinyyaml")

-- Default modes that were removed from config.example.yaml. Add names here when
-- a default mode is retired, so existing installs drop it too.
local RETIRED = { "Explain Code" }

local STATE = os.getenv("HOME") .. "/.hammerspoon/flickwise/data/config_sync.json"

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write(path, s)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local function split_lines(s)
    local lines = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    return lines
end

local function mode_name_of(line)
    local n = line:match('^  %- name:%s*"(.-)"%s*$') or line:match("^  %- name:%s*'(.-)'%s*$")
        or line:match("^  %- name:%s*([^#]-)%s*$")
    return n
end

-- { name → { first, last } } line ranges of each mode block in `lines`.
local function mode_blocks(lines)
    local blocks, order, in_modes = {}, {}, false
    for i, line in ipairs(lines) do
        if line:match("^modes:") then in_modes = true
        elseif line:match("^%S") and not line:match("^#") then in_modes = false end
        local name = in_modes and mode_name_of(line)
        if name then
            if #order > 0 then blocks[order[#order]].last = i - 1 end
            blocks[name] = { first = i, last = #lines }
            table.insert(order, name)
        end
    end
    -- Trim trailing blank lines from each block.
    for _, b in pairs(blocks) do
        while b.last > b.first and lines[b.last]:match("^%s*$") do b.last = b.last - 1 end
    end
    return blocks, order
end

local function load_state(path)
    local s = read(path)
    local ok, st = false, nil
    if s and s:match("%S") then ok, st = pcall(hs.json.decode, s) end
    if not ok or type(st) ~= "table" then st = {} end
    st.seen    = type(st.seen) == "table" and st.seen or {}
    st.retired = type(st.retired) == "table" and st.retired or {}
    return st
end

local function has(list, name)
    for _, n in ipairs(list) do if n == name then return true end end
    return false
end

function M.run(config_path, example_path, state_path)
    state_path = state_path or STATE
    local result = { added = {}, removed = {} }
    local config, example = read(config_path), read(example_path)
    if not config or not example then return result end
    if not tinyyaml.parse(config) then return result end   -- broken YAML: leave it alone

    local lines = split_lines(config)
    local ex_lines = split_lines(example)
    local have = mode_blocks(lines)
    local ex_blocks, ex_order = mode_blocks(ex_lines)
    local st = load_state(state_path)
    local changed = false

    -- Retire removed defaults (once per Mac).
    for _, name in ipairs(RETIRED) do
        if not has(st.retired, name) then
            local b = have[name]
            if b then
                local from = b.first
                if from > 1 and lines[from - 1]:match("^%s*$") then from = from - 1 end
                for _ = from, b.last do table.remove(lines, from) end
                table.insert(result.removed, name)
                changed = true
                have = mode_blocks(lines)
            end
            table.insert(st.retired, name)
        end
    end

    -- Add default modes this Mac hasn't been offered yet.
    for _, name in ipairs(ex_order) do
        if not has(st.seen, name) then
            if not have[name] then
                local b = ex_blocks[name]
                table.insert(lines, "")
                for i = b.first, b.last do table.insert(lines, ex_lines[i]) end
                table.insert(result.added, name)
                changed = true
            end
            table.insert(st.seen, name)
        end
    end

    if changed then
        write(config_path .. ".backup." .. os.date("%Y%m%d-%H%M%S"), config)
        local out = table.concat(lines, "\n") .. "\n"
        if not tinyyaml.parse(out) then return { added = {}, removed = {} } end  -- never write a broken file
        write(config_path, out)
    end
    local dir = state_path:match("^(.*)/")
    if dir and not hs.fs.attributes(dir) then hs.fs.mkdir(dir) end
    write(state_path, hs.json.encode(st))
    return result
end

return M
