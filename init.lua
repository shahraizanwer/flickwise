-- flickwise/init.lua — entrypoint: load config, bind hotkeys, start watcher
-- Wrapped in pcall so any error never crashes Hammerspoon.

local function main()
    local CONFIG_PATH = os.getenv("HOME") .. "/.hammerspoon/flickwise/config.yaml"

    local function safe_require(mod)
        local ok, result = pcall(require, mod)
        if not ok then
            print("[Flickwise] ERROR loading module " .. mod .. ": " .. tostring(result))
            return nil
        end
        return result
    end

    local notifier      = safe_require("flickwise.lib.notifier")
    local config_loader = safe_require("flickwise.lib.config_loader")
    local hotkey_manager= safe_require("flickwise.lib.hotkey_manager")
    local menubar_ui    = safe_require("flickwise.lib.menubar_ui")
    local watcher       = safe_require("flickwise.lib.watcher")
    local ai_client     = safe_require("flickwise.lib.ai_client")
    local prompt_editor = safe_require("flickwise.lib.prompt_editor")
    local mode_picker   = safe_require("flickwise.lib.mode_picker")
    local setup_wizard  = safe_require("flickwise.lib.setup_wizard")
    local hud           = safe_require("flickwise.lib.hud")
    local diff_bubble   = safe_require("flickwise.lib.diff_bubble")
    local radial_menu   = safe_require("flickwise.lib.radial_menu")
    local history       = safe_require("flickwise.lib.history")
    local history_window= safe_require("flickwise.lib.history_window")

    if not (notifier and config_loader and hotkey_manager and menubar_ui
            and watcher and ai_client and prompt_editor and mode_picker
            and setup_wizard and hud and diff_bubble and radial_menu and history and history_window) then
        hs.alert.show("Flickwise failed to load — check Hammerspoon console", 5)
        return
    end

    notifier.log("Flickwise starting up")
    hud.init()

    local active_config = nil
    local callbacks     = {}

    local function apply_config(config)
        active_config = config
        notifier.set_debug(config.debug or false)
        hud.configure(config.features.idle_pill)
        diff_bubble.configure(config.features.diff_bubble)
        diff_bubble.configure_card(config.features.result_card)
        diff_bubble.configure_replies(config.features.reply_helper)
        history.configure(config.features.history)
        menubar_ui.update(config, CONFIG_PATH, callbacks)
        hotkey_manager.bind_all(config.modes, config)
        notifier.log("Config applied — " .. #config.modes .. " modes active")
        mode_picker.setup(config)
        radial_menu.configure(config.features.radial_menu, config)
    end

    callbacks.reload = function()
        notifier.log("Reloading config…")
        local config, err = config_loader.load(CONFIG_PATH, notifier)
        if err then
            notifier.error("Config error", err)
            hud.error("Config error — see notification")
            notifier.log("Reload failed: " .. err)
            return
        end
        apply_config(config)
        hud.info("Config reloaded", #config.modes .. " modes")
        notifier.log("Config reloaded — " .. #config.modes .. " modes active")
    end

    callbacks.open_editor = function()
        prompt_editor.open(active_config, CONFIG_PATH, callbacks.reload)
    end

    callbacks.open_history = function()
        history_window.open()
    end

    callbacks.open_settings = function()
        if not active_config or (not active_config.use_glean and not active_config.has_api_key) then
            setup_wizard.open(CONFIG_PATH, function()
                callbacks.reload()
            end)
        else
            callbacks.open_editor()
        end
    end

    callbacks.quit = function()
        notifier.log("Flickwise quitting")
        hotkey_manager.unbind_all()
        mode_picker.teardown()
        radial_menu.teardown()
        history_window.close()
        watcher.stop()
        menubar_ui.destroy()
        prompt_editor.close()
        setup_wizard.close()
        diff_bubble.destroy()
        hud.destroy()
        notifier.log("Flickwise stopped")
    end

    -- Initial load
    local config, err = config_loader.load(CONFIG_PATH, notifier)
    if err then
        notifier.error("Config error on startup", err)
        notifier.log("Startup config error: " .. err)
        local fallback = {
            gemini_api_key = "", gemini_model = "gemini-flash-latest",
            has_api_key = false, modes = {}, debug = false, defaults = {}
        }
        menubar_ui.setup(fallback, CONFIG_PATH, callbacks)
    else
        menubar_ui.setup(config, CONFIG_PATH, callbacks)
        apply_config(config)

        -- Auto-open setup wizard on first run (Gemini backend, no API key set)
        if not config.use_glean and not config.has_api_key then
            hs.timer.doAfter(0.8, function()
                setup_wizard.open(CONFIG_PATH, function()
                    callbacks.reload()
                end)
            end)
        end
    end

    watcher.start(CONFIG_PATH, callbacks.reload)

    -- URL handler: `open "hammerspoon://flickwise-open"` (used by Flickwise.app)
    hs.urlevent.bind("flickwise-open", function()
        callbacks.open_settings()
    end)

    notifier.log("Flickwise ready")
end

local ok, err = pcall(main)
if not ok then
    print("[Flickwise] FATAL: " .. tostring(err))
    hs.alert.show("Flickwise fatal error — see Hammerspoon console", 5)
end
