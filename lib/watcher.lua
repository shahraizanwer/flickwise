-- watcher.lua — hot-reload config.yaml on save with debounce
-- Public API: watcher.start(config_path, on_change_fn), watcher.stop()

local M = {}

local _watcher       = nil
local _debounce_timer = nil
local DEBOUNCE_MS    = 500

function M.start(config_path, on_change_fn)
    M.stop()

    _watcher = hs.pathwatcher.new(config_path, function(paths)
        -- Debounce: reset timer on each rapid fire
        if _debounce_timer then
            _debounce_timer:stop()
        end
        _debounce_timer = hs.timer.doAfter(DEBOUNCE_MS / 1000, function()
            _debounce_timer = nil
            on_change_fn()
        end)
    end)

    if _watcher then
        _watcher:start()
    end
end

function M.stop()
    if _debounce_timer then
        _debounce_timer:stop()
        _debounce_timer = nil
    end
    if _watcher then
        _watcher:stop()
        _watcher = nil
    end
end

return M
