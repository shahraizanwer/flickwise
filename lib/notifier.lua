-- notifier.lua — user-facing alerts, notifications, and file logging
-- Public API: notifier.alert(msg, duration), notifier.notify(title, msg),
--             notifier.error(title, msg), notifier.log(msg), notifier.debug(msg),
--             notifier.set_debug(bool), notifier.api_key_missing()

local M = {}

local LOG_PATH      = os.getenv("HOME") .. "/.hammerspoon/flickwise/flickwise.log"
local LOG_MAX_BYTES = 1024 * 1024
local _debug_mode   = false

local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function write_log(level, msg)
    local line = string.format("[%s] [%s] %s\n", timestamp(), level, msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(line); f:close() end
end

function M.set_debug(enabled)
    _debug_mode = enabled
end

function M.alert(msg, duration)
    duration = duration or 1.5
    hs.alert.show(msg, duration)
    write_log("INFO", "ALERT: " .. msg)
end

function M.notify(title, msg)
    local n = hs.notify.new({ title = "Flickwise: " .. title, informativeText = msg })
    n:send()
    write_log("INFO", title .. ": " .. msg)
end

function M.error(title, msg)
    local n = hs.notify.new({
        title           = "Flickwise Error: " .. title,
        informativeText = msg,
        soundName       = hs.notify.defaultNotificationSound,
    })
    n:send()
    write_log("ERROR", title .. ": " .. msg)
end

function M.log(msg)
    write_log("INFO", msg)
end

function M.debug(msg)
    if _debug_mode then write_log("DEBUG", msg) end
end

function M.api_key_missing()
    local n = hs.notify.new({
        title           = "Flickwise: API key not configured",
        informativeText = "Click the \xe2\x9c\xa8 menu \xe2\x86\x92 Settings to add your key",
        soundName       = hs.notify.defaultNotificationSound,
    })
    n:send()
    write_log("ERROR", "API key not configured")
end

return M
