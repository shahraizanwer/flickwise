-- text_replacer.lua — capture the selection, call the AI, replace the selection
-- Capture/replace uses Accessibility directly when features.direct_replace is on
-- (no clipboard; see ax_text.lua), and falls back to ⌘C / ⌘V with clipboard restore.
-- Public API:
--   text_replacer.run(mode, cfg)
--   text_replacer.run_with_text(selected_text, original_clipboard, mode, cfg, ax_ctx)
--   text_replacer.capture_direct(cfg)   -> ax_ctx or nil  (used by the picker)
--   text_replacer.is_in_flight()

local M = {}

local PASTE_SLEEP_US   = 150000

local _in_flight = false

-- Last-resort capture when ⌘C put nothing on the clipboard (text only; the
-- result is still pasted).
local function capture_text_via_accessibility()
    local ctx = require("flickwise.lib.ax_text").read_selection(nil)
    return ctx and ctx.text or nil
end

local function direct_settings(cfg)
    local f = cfg.features and cfg.features.direct_replace
    return (f and f.enabled) and f or nil
end

-- Selection via Accessibility, or nil when the feature is off / unsupported here.
function M.capture_direct(cfg)
    local settings = direct_settings(cfg)
    if not settings then return nil end
    local ctx, why = require("flickwise.lib.ax_text").read_selection(settings)
    local notifier = require("flickwise.lib.notifier")
    if ctx then
        notifier.log("Captured via Accessibility (" .. tostring(ctx.app) .. ", "
            .. (ctx.web and "web content" or "native") .. ", writable=" .. tostring(ctx.writable) .. ")")
    else
        notifier.debug("Direct capture unavailable: " .. tostring(why) .. " — using the clipboard")
    end
    return ctx
end

local function paste(text, original_clipboard)
    local saved = original_clipboard
    if saved == nil then saved = hs.pasteboard.getContents() end
    hs.pasteboard.setContents(text)
    hs.eventtap.keyStroke({"cmd"}, "v")
    hs.timer.usleep(PASTE_SLEEP_US)
    if saved then hs.pasteboard.setContents(saved) end
end

local function dispatch(selected_text, original_clipboard, mode, cfg, ax_ctx)
    local notifier = require("flickwise.lib.notifier")
    local hud      = require("flickwise.lib.hud")
    local started  = hs.timer.secondsSinceEpoch()
    local client   = cfg.use_glean
        and require("flickwise.lib.glean_client")
        or  require("flickwise.lib.ai_client")

    local history = require("flickwise.lib.history")
    local front = hs.application.frontmostApplication()
    local app_name = (ax_ctx and ax_ctx.app) or (front and front:name()) or nil

    notifier.debug("Captured text (" .. #selected_text .. " chars): "
        .. selected_text:sub(1, 100))
    hud.working(mode.name)
    notifier.log("Running '" .. mode.name .. "'")

    client.transform(selected_text, mode, cfg,
        function(transformed)
            notifier.debug("Transformed (" .. #transformed .. " chars): "
                .. transformed:sub(1, 100))

            if mode.output == "show" then
                -- Explain-style mode: never touch the text, just show the answer.
                if original_clipboard then hs.pasteboard.setContents(original_clipboard) end
                hud.success("Done", string.format("%.1fs", hs.timer.secondsSinceEpoch() - started))
                if not require("flickwise.lib.diff_bubble").show_text(transformed, mode.name) then
                    hs.pasteboard.setContents(transformed)
                    hud.info("Answer copied to clipboard", mode.name)
                end
                history.record({ mode = mode.name, output = "show", app = app_name,
                                 original = selected_text, result = transformed })
                notifier.log("Mode '" .. mode.name .. "' shown (text not changed)")
                _in_flight = false
                return
            end

            local unchanged = (transformed == selected_text)
            local direct = false
            if not unchanged then
                local ax = require("flickwise.lib.ax_text")
                local settings = direct_settings(cfg)
                local can, why = false, "captured with the clipboard"
                if ax_ctx then can, why = ax.can_write(ax_ctx, settings) end
                if can then
                    direct, why = ax.replace(ax_ctx, transformed)
                    if direct and why then notifier.log("Direct replace: " .. why) end
                end
                if direct then
                    notifier.log("Replaced via Accessibility (clipboard untouched)")
                elseif why == "selection changed while working" then
                    -- Pasting now could overwrite different text; hand the result over instead.
                    hs.pasteboard.setContents(transformed)
                    hud.error("Text changed while working — result copied to clipboard")
                    notifier.log("Not replaced: " .. why)
                    _in_flight = false
                    return
                else
                    notifier.debug("Paste fallback: " .. tostring(why))
                    paste(transformed, original_clipboard)
                end
            elseif original_clipboard then
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
                history.record({ mode = mode.name, output = "replace", app = app_name,
                                 original = selected_text, result = transformed })
                if mode.diff_bubble ~= false then
                    require("flickwise.lib.diff_bubble").show(
                        selected_text, transformed, mode.name, hs.window.focusedWindow(),
                        direct and ax_ctx or nil)
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

    local ax_ctx = M.capture_direct(cfg)
    if ax_ctx then
        dispatch(ax_ctx.text, nil, mode, cfg, ax_ctx)
        return
    end
    
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

function M.run_with_text(selected_text, original_clipboard, mode, cfg, ax_ctx)
    if _in_flight then
        require("flickwise.lib.hud").info("Still working on the last one…")
        return
    end
    _in_flight = true
    require("flickwise.lib.diff_bubble").dismiss()

    dispatch(selected_text, original_clipboard, mode, cfg, ax_ctx)
end

function M.is_in_flight()
    return _in_flight
end

return M
