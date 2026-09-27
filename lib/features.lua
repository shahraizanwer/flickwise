-- features.lua — the `features:` section of config.yaml (every optional feature
-- is switchable here, and nowhere else).
-- Public API:
--   M.DEFAULTS                        default settings for each feature
--   M.MENU                            ordered { key, title } list for the menu bar
--   M.normalize(raw, notifier)        merge raw YAML onto defaults -> features table
--   M.set_enabled(path, key, bool)    rewrite `features.<key>.enabled` in config.yaml

local M = {}

M.DEFAULTS = {
    idle_pill = {
        enabled = false,          -- tiny resting pill at bottom-center when idle
    },
    diff_bubble = {
        enabled          = true,  -- "what changed" bubble after each fix
        duration_seconds = 6,     -- auto-dismiss (paused while hovered)
        undo_hotkey      = { "cmd", "z" },
        undo_method      = "app", -- "app" = send ⌘Z to the app, "reselect" = select the result and paste the original
        context_words    = 8,     -- unchanged words kept around each change; longer stretches collapse to "…"
    },
    direct_replace = {
        enabled      = true,      -- read/replace the selection through Accessibility, not the clipboard
        web_content  = "paste",   -- web pages & Electron apps: "paste" (safe) or "direct" (may confuse web apps)
        exclude_apps = {},        -- app names that always use the clipboard method, e.g. { "Terminal" }
    },
    radial_menu = {
        enabled = true,           -- hold the trigger, flick toward a mode, release to apply
        trigger = "right_option", -- right_option | right_command | right_control | right_shift, or a chord like { "ctrl", "alt", "space" }
        hold_ms = 150,            -- modifier triggers: how long to hold before the ring opens
        anchor  = "mouse",        -- mouse | caret (falls back to mouse when the app doesn't expose the caret)
        modes   = {},             -- mode names clockwise from the top; empty = all modes in config order (max 8)
    },
}

-- Settings that may legitimately be more than one type.
local FLEXIBLE = { ["radial_menu.trigger"] = { string = true, table = true } }

M.MODIFIER_TRIGGERS = { right_option = true, right_command = true, right_control = true, right_shift = true }

M.MENU = {
    { key = "idle_pill",   title = "Resting Pill When Idle" },
    { key = "diff_bubble", title = "“What Changed” Bubble + Undo" },
    { key = "radial_menu", title = "Radial Menu at Cursor" },
    { key = "direct_replace", title = "Replace Without Clipboard" },
}

local UNDO_METHODS = { app = true, reselect = true }

local function warn(notifier, msg)
    if notifier then notifier.log("WARNING: features: " .. msg) end
end

function M.normalize(raw, notifier)
    local out = {}
    for key, defaults in pairs(M.DEFAULTS) do
        local f = {}
        for k, v in pairs(defaults) do f[k] = v end
        local given = nil
        if type(raw) == "table" then given = raw[key] end
        if type(given) == "table" then
            for k, v in pairs(given) do
                if defaults[k] == nil then
                    warn(notifier, key .. "." .. tostring(k) .. " is not a known setting — ignored")
                elseif FLEXIBLE[key .. "." .. k] then
                    if FLEXIBLE[key .. "." .. k][type(v)] then f[k] = v
                    else warn(notifier, key .. "." .. k .. " has the wrong type — using default") end
                elseif type(v) ~= type(defaults[k]) then
                    warn(notifier, key .. "." .. k .. " should be a " .. type(defaults[k]) .. " — using default")
                else
                    f[k] = v
                end
            end
        elseif given ~= nil then
            -- Shorthand: `diff_bubble: false`
            f.enabled = (given == true)
        end
        out[key] = f
    end

    local db = out.diff_bubble
    if not UNDO_METHODS[db.undo_method] then
        warn(notifier, "diff_bubble.undo_method must be 'app' or 'reselect' — using 'app'")
        db.undo_method = "app"
    end
    if #db.undo_hotkey < 2 then
        warn(notifier, "diff_bubble.undo_hotkey needs a modifier and a key — using ⌘Z")
        db.undo_hotkey = M.DEFAULTS.diff_bubble.undo_hotkey
    end
    if db.duration_seconds <= 0 then db.duration_seconds = M.DEFAULTS.diff_bubble.duration_seconds end

    local dr = out.direct_replace
    if dr.web_content ~= "paste" and dr.web_content ~= "direct" then
        warn(notifier, "direct_replace.web_content must be 'paste' or 'direct' — using 'paste'")
        dr.web_content = "paste"
    end

    local rm = out.radial_menu
    if type(rm.trigger) == "string" and not M.MODIFIER_TRIGGERS[rm.trigger] then
        warn(notifier, "radial_menu.trigger '" .. rm.trigger .. "' is unknown — using right_option")
        rm.trigger = "right_option"
    elseif type(rm.trigger) == "table" and #rm.trigger < 2 then
        warn(notifier, "radial_menu.trigger chord needs a modifier and a key — using right_option")
        rm.trigger = "right_option"
    end
    if rm.anchor ~= "mouse" and rm.anchor ~= "caret" then rm.anchor = "mouse" end
    if rm.hold_ms < 0 then rm.hold_ms = M.DEFAULTS.radial_menu.hold_ms end
    return out
end

-- ── config.yaml writer ────────────────────────────────────────────────────────
-- Edits only the one `enabled:` line (inserting the section if missing) so
-- comments and the rest of the file stay untouched. The `features:` block is
-- kept above `modes:` because the prompt editor appends new modes at EOF.

function M.set_enabled(path, key, enabled)
    local f = io.open(path, "r")
    if not f then return false, "Cannot read " .. path end
    local content = f:read("*a")
    f:close()

    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end

    local value = enabled and "true" or "false"

    local feat_i
    for i, line in ipairs(lines) do
        if line:match("^features:%s*$") or line:match("^features:%s*#") then feat_i = i; break end
    end

    if not feat_i then
        local at = #lines + 1
        for i, line in ipairs(lines) do
            if line:match("^modes:") then at = i; break end
        end
        local block = { "features:", "  " .. key .. ":", "    enabled: " .. value, "" }
        for j = #block, 1, -1 do table.insert(lines, at, block[j]) end
    else
        -- End of the features block: first non-blank, non-comment line at column 0.
        local feat_end = #lines + 1
        for i = feat_i + 1, #lines do
            if lines[i]:match("^%S") and not lines[i]:match("^#") then feat_end = i; break end
        end

        local key_i
        for i = feat_i + 1, feat_end - 1 do
            if lines[i]:match("^  " .. key .. ":") then key_i = i; break end
        end

        if not key_i then
            table.insert(lines, feat_i + 1, "    enabled: " .. value)
            table.insert(lines, feat_i + 1, "  " .. key .. ":")
        elseif not lines[key_i]:match("^  " .. key .. ":%s*$") and not lines[key_i]:match("^  " .. key .. ":%s*#") then
            -- Shorthand form `  key: true` — rewrite in place.
            lines[key_i] = "  " .. key .. ": " .. value
        else
            local done = false
            for i = key_i + 1, feat_end - 1 do
                local line = lines[i]
                if line:match("^%s*$") or line:match("^%s*#") then
                    -- skip
                elseif not line:match("^    ") then
                    break
                elseif line:match("^    enabled:") then
                    -- Keep a trailing comment in the same column.
                    local before, comment = line:match("^(    enabled:%s*%S+)(%s+#.*)$")
                    local new = "    enabled: " .. value
                    if comment then
                        local pad = math.max(1, #before + #comment:match("^%s+") - #new)
                        new = new .. string.rep(" ", pad) .. comment:gsub("^%s+", "")
                    end
                    lines[i] = new
                    done = true
                    break
                end
            end
            if not done then table.insert(lines, key_i + 1, "    enabled: " .. value) end
        end
    end

    local f2 = io.open(path, "w")
    if not f2 then return false, "Cannot write " .. path end
    f2:write(table.concat(lines, "\n") .. "\n")
    f2:close()
    return true
end

return M
