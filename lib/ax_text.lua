-- ax_text.lua — read and replace the selected text through Accessibility (IDEAS 1.4)
-- No ⌘C/⌘V and no clipboard: the focused element's AXSelectedText is read
-- directly, and the result is written back with AXSelectedText, then verified.
-- AX ranges count UTF-16 code units, so lengths are converted with u16len().
-- Public API:
--   M.read_selection(settings)   -> ctx or nil, reason
--        ctx = { text, el, range = {location,length}, app, writable, web }
--   M.can_write(ctx, settings)   -> bool, reason
--   M.replace(ctx, new_text)     -> ok, reason   (on success ctx.new_text/new_range are set)
--   M.restore(ctx)               -> ok, reason   (undo a replace(): puts ctx.text back and reselects it)

local M = {}

local WEB_ANCESTOR_DEPTH = 40

local function u16len(s)
    local ok, n = pcall(function()
        local c = 0
        for _, cp in utf8.codes(s) do c = c + (cp > 0xFFFF and 2 or 1) end
        return c
    end)
    return ok and n or #s
end
M.u16len = u16len

local function attr(el, name)
    local ok, v = pcall(function() return el:attributeValue(name) end)
    return ok and v or nil
end

local function set_attr(el, name, value)
    local ok, res, err = pcall(function() return el:setAttributeValue(name, value) end)
    if not ok then return false, tostring(res) end
    if res == nil then return false, tostring(err or "rejected") end
    return true
end

-- Inside a web page (browsers, Electron apps)? Writing AXSelectedText there
-- changes the DOM without the page's input events, so frameworks like React
-- keep the old text. Those get the paste method instead.
local function in_web_content(el)
    if attr(el, "AXDOMIdentifier") ~= nil or attr(el, "AXDOMClassList") ~= nil then return true end
    local cur = el
    for _ = 1, WEB_ANCESTOR_DEPTH do
        if not cur then return false end
        if attr(cur, "AXRole") == "AXWebArea" then return true end
        cur = attr(cur, "AXParent")
    end
    return false
end

local function excluded(app_name, list)
    if not app_name or type(list) ~= "table" then return false end
    local lower = app_name:lower()
    for _, n in ipairs(list) do
        if tostring(n):lower() == lower then return true end
    end
    return false
end

function M.read_selection(settings)
    local app = hs.application.frontmostApplication()
    local app_name = app and app:name() or nil
    if excluded(app_name, settings and settings.exclude_apps) then
        return nil, "excluded app"
    end

    local el = attr(hs.axuielement.systemWideElement(), "AXFocusedUIElement")
    if not el then return nil, "no focused element" end
    if attr(el, "AXSubrole") == "AXSecureTextField" then return nil, "secure field" end

    local text = attr(el, "AXSelectedText")
    if type(text) ~= "string" or text == "" then return nil, "no AX selection" end

    local range = attr(el, "AXSelectedTextRange")
    if type(range) ~= "table" or range.location == nil then range = nil end

    local settable = false
    pcall(function() settable = el:isAttributeSettable("AXSelectedText") == true end)

    return {
        text     = text,
        el       = el,
        range    = range and { location = range.location, length = range.length } or nil,
        app      = app_name,
        writable = settable and range ~= nil,
        web      = in_web_content(el),
    }
end

function M.can_write(ctx, settings)
    if not ctx then return false, "no context" end
    if not ctx.writable then return false, "selection isn't writable through Accessibility" end
    if ctx.web and (settings and settings.web_content) ~= "direct" then
        return false, "web content (uses paste)"
    end
    return true
end

-- Make sure `range` is selected and holds `expected`; reselects if the user moved.
local function select_expected(el, range, expected)
    if attr(el, "AXSelectedText") == expected then return true end
    if range then set_attr(el, "AXSelectedTextRange", range) end
    return attr(el, "AXSelectedText") == expected
end

-- Write `new` over the current selection and confirm the field actually changed.
local function write_verified(el, old, new)
    local before = attr(el, "AXValue")
    local count_before = attr(el, "AXNumberOfCharacters")
    local ok, err = set_attr(el, "AXSelectedText", new)
    if not ok then return false, "write rejected: " .. err end

    local after = attr(el, "AXValue")
    if type(before) == "string" and type(after) == "string" then
        if after == before then return false, "app ignored the write" end
        if not after:find(new, 1, true) then
            -- Changed, but not verbatim (e.g. the app normalized line endings).
            -- Don't fall back to a paste, since that could insert the text twice.
            return true, "changed (not verbatim)"
        end
        return true
    end
    local count_after = attr(el, "AXNumberOfCharacters")
    if type(count_before) == "number" and type(count_after) == "number" then
        if count_after == count_before and u16len(new) ~= u16len(old) then
            return false, "app ignored the write"
        end
        return true, "verified by length"
    end
    return true, "unverified (no AXValue)"
end

function M.replace(ctx, new_text)
    local el = ctx.el
    if not select_expected(el, ctx.range, ctx.text) then
        return false, "selection changed while working"
    end
    local ok, why = write_verified(el, ctx.text, new_text)
    if not ok then return false, why end
    ctx.new_text  = new_text
    ctx.new_range = { location = ctx.range.location, length = u16len(new_text) }
    return true, why
end

function M.restore(ctx)
    if not (ctx and ctx.new_range) then return false, "nothing to restore" end
    local el = ctx.el
    if not select_expected(el, ctx.new_range, ctx.new_text) then
        return false, "the replaced text was edited"
    end
    local ok, why = write_verified(el, ctx.new_text, ctx.text)
    if not ok then return false, why end
    -- Leave the original selected, as it was before the fix.
    set_attr(el, "AXSelectedTextRange", { location = ctx.range.location, length = u16len(ctx.text) })
    return true
end

return M
