-- hotkey_manager.lua — bind and unbind hotkeys from config modes
-- Public API: hotkey_manager.bind_all(modes, cfg), hotkey_manager.unbind_all()

local M = {}

local _bound = {}

-- Convert config hotkey array ["cmd","shift","g"] into mods + key
local function parse_hotkey(hk)
    local mods = {}
    local key  = nil
    for _, part in ipairs(hk) do
        local p = part:lower()
        if p == "cmd" or p == "command" then
            table.insert(mods, "cmd")
        elseif p == "shift" then
            table.insert(mods, "shift")
        elseif p == "ctrl" or p == "control" then
            table.insert(mods, "ctrl")
        elseif p == "alt" or p == "opt" or p == "option" then
            table.insert(mods, "alt")
        else
            key = p
        end
    end
    return mods, key
end

function M.bind_all(modes, cfg)
    local notifier      = require("flickwise.lib.notifier")
    local text_replacer = require("flickwise.lib.text_replacer")

    M.unbind_all()

    for _, mode in ipairs(modes) do
        local mods, key = parse_hotkey(mode.hotkey)
        if not key then
            notifier.log("WARNING: mode '" .. mode.name .. "' has no key in hotkey array — skipped")
        else
            local captured_mode = mode
            local captured_cfg = cfg
            local ok, hk = pcall(hs.hotkey.bind, mods, key, function()
                text_replacer.run(captured_mode, captured_cfg)
            end)
            if ok and hk then
                table.insert(_bound, hk)
                notifier.log("Bound hotkey " .. table.concat(mode.hotkey, "+") .. " -> " .. mode.name)
            else
                notifier.log("WARNING: could not bind hotkey for '" .. mode.name .. "': " .. tostring(hk))
            end
        end
    end
end

function M.unbind_all()
    for _, hk in ipairs(_bound) do
        pcall(function() hk:delete() end)
    end
    _bound = {}
end

function M.bound_count()
    return #_bound
end

return M
