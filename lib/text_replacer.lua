-- text_replacer.lua — clipboard capture, API dispatch, and paste-back
-- Public API:
--   text_replacer.run(mode, cfg)
--   text_replacer.run_with_text(selected_text, original_clipboard, mode, cfg)
--   text_replacer.is_in_flight()

local M = {}

local PASTE_SLEEP_US   = 150000

local _in_flight = false

-- Try to capture text using accessibility API as fallback
local function capture_text_via_accessibility()
    local notifier = require("flickwise.lib.notifier")
    notifier.debug("Attempting to capture text via accessibility API...")
    
    -- Get the focused element
    local app = hs.application.frontmostApplication()
    if not app then
        notifier.debug("No frontmost app found")
        return nil
    end
    
    local appElement = app:getWindow()
    if not appElement then
        notifier.debug("Could not get app window element")
        return nil
    end
    
    -- Try to find focused text field and get selected text
    local sysElement = hs.axuielement.systemElement()
    if sysElement then
        local focusedElement = sysElement:attributeValue("AXFocusedUIElement")
        if focusedElement then
            local selectedText = focusedElement:attributeValue("AXSelectedText")
            if selectedText and selectedText ~= "" then
                notifier.debug("Captured via accessibility: " .. (#selectedText) .. " chars")
                return selectedText
            end
        end
    end
    
    return nil
end

local function dispatch(selected_text, original_clipboard, mode, cfg)
    local notifier = require("flickwise.lib.notifier")
    local hud      = require("flickwise.lib.hud")
    local started  = hs.timer.secondsSinceEpoch()
    local client   = cfg.use_glean
        and require("flickwise.lib.glean_client")
        or  require("flickwise.lib.ai_client")

    notifier.debug("Captured text (" .. #selected_text .. " chars): "
        .. selected_text:sub(1, 100))
    hud.working(mode.name)
    notifier.log("Running '" .. mode.name .. "'")

    client.transform(selected_text, mode, cfg,
        function(transformed)
            notifier.debug("Transformed (" .. #transformed .. " chars): "
                .. transformed:sub(1, 100))

            hs.pasteboard.setContents(transformed)
            hs.eventtap.keyStroke({"cmd"}, "v")
            hs.timer.usleep(PASTE_SLEEP_US)

            if original_clipboard then
                hs.pasteboard.setContents(original_clipboard)
            end

            local sound_name = cfg.defaults and cfg.defaults.sound
            if sound_name then
                local snd = hs.sound.getByName(sound_name)
                if snd then snd:play() end
            end

            local elapsed = string.format("%.1fs", hs.timer.secondsSinceEpoch() - started)
            if transformed == selected_text then
                hud.success("No changes needed", elapsed)
            else
                hud.success("Done", elapsed)
                if mode.diff_bubble ~= false then
                    require("flickwise.lib.diff_bubble").show(
                        selected_text, transformed, mode.name, hs.window.focusedWindow())
                end
            end
            notifier.log("Mode '" .. mode.name .. "' completed successfully")
            _in_flight = false
        end,
        function(err)
            if err == "no_api_key" then
                hud.error("API key not set — open Settings from the menu bar")
            elseif err == "invalid_api_key" then
                hud.error("Invalid API key — update it in Settings")
            elseif err == "rate_limited" then
                hud.error("Rate limited — try again in a moment")
            else
                hud.error("Couldn't transform — " .. tostring(err):sub(1, 60))
            end
            notifier.log("ERROR: transform failed: " .. tostring(err))
            if original_clipboard then
                hs.pasteboard.setContents(original_clipboard)
            end
            _in_flight = false
        end
    )
end

function M.run(mode, cfg)
    local notifier = require("flickwise.lib.notifier")

    if _in_flight then
        require("flickwise.lib.hud").info("Still working on the last one…")
        return
    end
    _in_flight = true
    require("flickwise.lib.diff_bubble").dismiss()

    notifier.debug("=== Flickwise Capture Started ===")
    
    -- Get the current clipboard content BEFORE trying to copy
    local original_clipboard = hs.pasteboard.getContents()
    notifier.debug("Original clipboard (" .. (original_clipboard and #original_clipboard or 0) .. " chars)")
    
    -- Add a small delay to ensure we're ready
    hs.timer.usleep(100000)
    
    -- Send Cmd+C to copy selected text
    notifier.debug("Sending Cmd+C...")
    hs.eventtap.keyStroke({"cmd"}, "c")
    
    -- Poll for clipboard change with extended timeout
    local selected_text = nil
    local deadline = hs.timer.secondsSinceEpoch() + 3.0
    local attempts = 0
    
    notifier.debug("Starting clipboard polling (3 second timeout)...")
    repeat
        hs.timer.usleep(150000)  -- Increased polling interval
        local t = hs.pasteboard.getContents()
        attempts = attempts + 1
        
        local t_len = t and #t or 0
        local changed = (t and original_clipboard) and (t ~= original_clipboard)
        notifier.debug("Poll attempt " .. attempts .. ": " .. t_len .. " chars, changed=" .. tostring(changed))
        
        -- Check if we got new text that's different from original
        if t and t ~= "" and t ~= original_clipboard then 
            selected_text = t
            notifier.debug("✓ Text captured on attempt " .. attempts)
            break 
        end
    until hs.timer.secondsSinceEpoch() >= deadline

    if not selected_text or selected_text == "" then
        notifier.log("Clipboard capture failed after " .. attempts .. " attempts, trying accessibility API...")
        
        -- Fallback: try to capture using accessibility API
        selected_text = capture_text_via_accessibility()
        
        if not selected_text or selected_text == "" then
            require("flickwise.lib.hud").error("Select some text first")
            notifier.log("ERROR: Could not capture text via clipboard OR accessibility API")
            notifier.log("Make sure:")
            notifier.log("  1. Text is selected before pressing the hotkey")
            notifier.log("  2. Hammerspoon has Accessibility permissions (System Settings > Privacy & Security > Accessibility)")
            notifier.log("  3. Try the hotkey picker (Cmd+Shift+P) first, then select a transformation")
            if original_clipboard then hs.pasteboard.setContents(original_clipboard) end
            _in_flight = false
            return
        else
            notifier.log("✓ Captured via accessibility API")
        end
    end

    notifier.debug("=== Flickwise Capture Successful ===")
    dispatch(selected_text, original_clipboard, mode, cfg)
end

function M.run_with_text(selected_text, original_clipboard, mode, cfg)
    if _in_flight then
        require("flickwise.lib.hud").info("Still working on the last one…")
        return
    end
    _in_flight = true
    require("flickwise.lib.diff_bubble").dismiss()

    dispatch(selected_text, original_clipboard, mode, cfg)
end

function M.is_in_flight()
    return _in_flight
end

return M
