-- menubar_ui.lua — status-bar icon and dropdown menu
-- Public API: menubar_ui.setup(config, config_path, callbacks),
--             menubar_ui.update(config, config_path, callbacks),
--             menubar_ui.set_warning(bool),
--             menubar_ui.destroy()

local M = {}

local _menubar = nil
local _warning = false
local _icon    = nil

local MOD_GLYPHS = {
    cmd = "⌘", command = "⌘",
    shift = "⇧",
    ctrl = "⌃", control = "⌃",
    alt = "⌥", opt = "⌥", option = "⌥",
}

local KEY_GLYPHS = {
    up = "↑", down = "↓", left = "←", right = "→",
    space = "Space", ["return"] = "↩", tab = "⇥",
    escape = "⎋", delete = "⌫",
}

local function hotkey_label(hk)
    if not hk then return "" end
    local parts = {}
    for _, p in ipairs(hk) do
        local lower = p:lower()
        table.insert(parts, MOD_GLYPHS[lower] or KEY_GLYPHS[lower] or p:upper())
    end
    return table.concat(parts, "")
end

local MARK_PATH = os.getenv("HOME") .. "/.hammerspoon/flickwise/assets/flickwise-mark.svg"

-- Monochrome template sparkle, used only if the logo mark can't be loaded.
local function sparkle_icon()
    local c = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
    local function star(cx, cy, r)
        local k = r * 0.16
        return {
            type = "segments", action = "fill", closed = true,
            fillColor = { black = 1, alpha = 1 },
            coordinates = {
                { x = cx,     y = cy - r },
                { x = cx + r, y = cy,     c1x = cx + k, c1y = cy - k, c2x = cx + k, c2y = cy - k },
                { x = cx,     y = cy + r, c1x = cx + k, c1y = cy + k, c2x = cx + k, c2y = cy + k },
                { x = cx - r, y = cy,     c1x = cx - k, c1y = cy + k, c2x = cx - k, c2y = cy + k },
                { x = cx,     y = cy - r, c1x = cx - k, c1y = cy - k, c2x = cx - k, c2y = cy - k },
            },
        }
    end
    c:appendElements(star(7.5, 10, 7), star(14.5, 3.8, 3))
    local img = c:imageFromCanvas()
    c:delete()
    return img
end

-- Flickwise mark as a template image so it matches native menu bar items
-- in both light and dark mode.
local function menubar_icon()
    if _icon then return _icon end
    local img = hs.image.imageFromPath(MARK_PATH) or sparkle_icon()
    _icon = img:setSize({ w = 18, h = 18 }):template(true)
    return _icon
end

-- Menu title with the hotkey right-aligned in secondary color, like native menus.
local function styled_title(name, shortcut, tab_at)
    local font = hs.styledtext.defaultFonts.menu
    if not shortcut or shortcut == "" then return name end
    local st = hs.styledtext.new(name .. "\t" .. shortcut, {
        font = font,
        paragraphStyle = { tabStops = { { location = tab_at, tabStopType = "right" } } },
    })
    return st:setStyle({ color = { list = "System", name = "secondaryLabelColor" } },
                       #name + 2, #st)
end

local function header(text)
    return {
        title = hs.styledtext.new(text, {
            font  = { name = hs.styledtext.defaultFonts.menu.name, size = 11 },
            color = { list = "System", name = "tertiaryLabelColor" },
        }),
        disabled = true,
    }
end

local function build_menu(config, config_path, callbacks)
    local hud      = require("flickwise.lib.hud")
    local features = require("flickwise.lib.features")
    local items = {}

    -- Right tab stop sits just past the longest mode name.
    local font  = hs.styledtext.defaultFonts.menu
    local widest = 120
    for _, mode in ipairs(config.modes) do
        local sz = hs.drawing.getTextDrawingSize(mode.name, { font = font.name, size = font.size })
        if sz and sz.w > widest then widest = sz.w end
    end
    local tab_at = math.ceil(widest) + 70

    if _warning then
        table.insert(items, header("⚠︎  Needs attention — check Settings"))
        table.insert(items, { title = "-" })
    end

    table.insert(items, header("MODES"))
    for _, mode in ipairs(config.modes) do
        local captured, captured_cfg = mode, config
        table.insert(items, {
            title = styled_title(mode.name, hotkey_label(mode.hotkey), tab_at),
            fn    = function()
                require("flickwise.lib.text_replacer").run(captured, captured_cfg)
            end,
        })
    end
    if config.picker_hotkey then
        table.insert(items, {
            title    = styled_title("All modes…", hotkey_label(config.picker_hotkey), tab_at),
            disabled = true,
        })
    end

    table.insert(items, { title = "-" })

    table.insert(items, { title = "Edit Modes…", fn = callbacks.open_editor })
    table.insert(items, { title = "History & Progress…", fn = callbacks.open_history })
    -- Every optional feature is a toggle here; it writes `features.<key>.enabled`
    -- in config.yaml and the file watcher reloads the config.
    local feature_items = {}
    for _, f in ipairs(features.MENU) do
        local on = config.features and config.features[f.key] and config.features[f.key].enabled
        table.insert(feature_items, {
            title   = f.title,
            checked = on == true,
            fn      = function()
                local ok, err = features.set_enabled(config_path, f.key, not on)
                if not ok then hud.error("Couldn't save — " .. tostring(err)) end
            end,
        })
    end
    table.insert(items, { title = "Features", menu = feature_items })
    if not config.use_glean then
        table.insert(items, { title = "API Key…", fn = callbacks.open_settings })
    end

    table.insert(items, { title = "-" })

    table.insert(items, {
        title = "Advanced",
        menu  = {
            { title = "Open Config File", fn = function() hs.execute('open "' .. config_path .. '"') end },
            { title = "Reload Config",    fn = callbacks.reload },
            { title = "Open Logs", fn = function()
                hs.execute('open "' .. os.getenv("HOME") .. '/.hammerspoon/flickwise/flickwise.log"')
            end },
        },
    })
    table.insert(items, { title = "Quit Flickwise", fn = callbacks.quit })

    return items
end

local function apply_icon()
    if not _menubar then return end
    _menubar:setIcon(menubar_icon(), true)
    _menubar:setTitle(_warning and "!" or nil)
end

function M.set_warning(enabled)
    _warning = enabled
    apply_icon()
end

function M.setup(config, config_path, callbacks)
    if _menubar then _menubar:delete() end
    _menubar = hs.menubar.new()
    if not _menubar then return end
    apply_icon()
    _menubar:setTooltip("Flickwise")
    _menubar:setMenu(function() return build_menu(config, config_path, callbacks) end)
end

function M.update(config, config_path, callbacks)
    if not _menubar then
        M.setup(config, config_path, callbacks)
        return
    end
    apply_icon()
    _menubar:setMenu(function() return build_menu(config, config_path, callbacks) end)
end

function M.destroy()
    if _menubar then _menubar:delete(); _menubar = nil end
end

return M
