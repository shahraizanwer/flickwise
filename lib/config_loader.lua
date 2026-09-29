-- config_loader.lua — parse, validate, and return config from config.yaml
-- Public API: config_loader.load(path, notifier) -> config, err

local M = {}

local tinyyaml = require("flickwise.lib.tinyyaml")
local features = require("flickwise.lib.features")

local DEFAULT_MODEL = "gemini-flash-latest"

local DEFAULT_DEFAULTS = {
    timeout_seconds = 30,
    debug           = false,
    sound           = "Tink",
}

local function trim(s)
    if type(s) ~= "string" then return tostring(s) end
    return s:match("^%s*(.-)%s*$")
end

local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "Cannot open file: " .. (err or path) end
    local contents = f:read("*a")
    f:close()
    return contents
end

local function validate(cfg, notifier)
    if type(cfg) ~= "table" then
        return nil, "Config must be a YAML mapping"
    end

    -- glean_binary_path (if set, Glean is used as backend instead of Gemini)
    local glean_path = ""
    if cfg.glean_binary_path ~= nil then
        glean_path = trim(tostring(cfg.glean_binary_path))
    end

    -- gemini_api_key
    local api_key = ""
    if cfg.gemini_api_key ~= nil then
        api_key = trim(tostring(cfg.gemini_api_key))
    end

    -- gemini_model
    local model = DEFAULT_MODEL
    if cfg.gemini_model and trim(tostring(cfg.gemini_model)) ~= "" then
        model = trim(tostring(cfg.gemini_model))
    end

    -- defaults
    local defaults = {}
    for k, v in pairs(DEFAULT_DEFAULTS) do defaults[k] = v end
    if type(cfg.defaults) == "table" then
        if cfg.defaults.timeout_seconds ~= nil then
            defaults.timeout_seconds = cfg.defaults.timeout_seconds
        end
        if cfg.defaults.debug ~= nil then
            defaults.debug = (cfg.defaults.debug == true)
        end
        if cfg.defaults.sound ~= nil then
            defaults.sound = (cfg.defaults.sound == false) and false
                             or tostring(cfg.defaults.sound)
        end
    end

    if cfg.debug ~= nil then
        defaults.debug = (cfg.debug == true)
    end

    -- picker_hotkey (optional)
    local picker_hotkey = nil
    if type(cfg.picker_hotkey) == "table" and #cfg.picker_hotkey >= 2 then
        picker_hotkey = cfg.picker_hotkey
    end

    -- modes
    if type(cfg.modes) ~= "table" or #cfg.modes == 0 then
        return nil, "modes array is missing or empty"
    end

    local seen_hotkeys = {}
    local valid_modes  = {}

    for idx, mode in ipairs(cfg.modes) do
        local prefix = string.format("modes[%d]", idx)

        if not mode.name or trim(tostring(mode.name)) == "" then
            return nil, prefix .. " is missing 'name'"
        end
        if not mode.system_prompt or trim(tostring(mode.system_prompt)) == "" then
            return nil, prefix .. " (" .. tostring(mode.name) .. ") is missing 'system_prompt'"
        end

        -- hotkey is optional — modes without one are picker-only
        local hotkey = nil
        if type(mode.hotkey) == "table" and #mode.hotkey >= 2 then
            local hk_key = table.concat(mode.hotkey, "+"):lower()
            if seen_hotkeys[hk_key] then
                local warn = "Duplicate hotkey " .. hk_key .. " for mode '"
                    .. mode.name .. "' — hotkey skipped"
                if notifier then notifier.log("WARNING: " .. warn) end
            else
                seen_hotkeys[hk_key] = mode.name
                hotkey = mode.hotkey
            end
        end

        -- output: "replace" (default) swaps the selection; "show" leaves it alone and
        -- shows the answer in a card (e.g. explaining what a message means);
        -- "replies" expects JSON { meaning, replies = [{label, text}] } and shows pickable replies
        local output = mode.output and trim(tostring(mode.output)):lower() or "replace"
        if output ~= "replace" and output ~= "show" and output ~= "replies" then
            if notifier then
                notifier.log("WARNING: " .. prefix .. " output must be 'replace', 'show' or 'replies' — using 'replace'")
            end
            output = "replace"
        end

        -- temperature (optional, Gemini only): 0 = most literal/predictable, 2 = most creative
        local temperature = nil
        if mode.temperature ~= nil then
            local t = tonumber(mode.temperature)
            if t and t >= 0 and t <= 2 then
                temperature = t
            elseif notifier then
                notifier.log("WARNING: " .. prefix .. " temperature must be a number from 0 to 2 — ignored")
            end
        end

        table.insert(valid_modes, {
            name            = trim(tostring(mode.name)),
            hotkey          = hotkey,
            system_prompt   = tostring(mode.system_prompt),
            timeout_seconds = mode.timeout_seconds or defaults.timeout_seconds,
            -- per-mode opt-out, e.g. `diff_bubble: false` for modes whose output isn't an edit
            diff_bubble     = (mode.diff_bubble ~= false),
            output          = output,
            temperature     = temperature,
        })
    end

    if #valid_modes == 0 then
        return nil, "No valid modes found"
    end

    return {
        glean_binary_path = glean_path,
        use_glean         = (glean_path ~= ""),
        gemini_api_key    = api_key,
        gemini_model      = model,
        has_api_key       = (api_key ~= ""),
        defaults          = defaults,
        modes             = valid_modes,
        debug             = defaults.debug,
        picker_hotkey     = picker_hotkey,
        features          = features.normalize(cfg.features, notifier),
    }
end

function M.load(path, notifier)
    local contents, read_err = read_file(path)
    if not contents then return nil, read_err end

    local raw, parse_err = tinyyaml.parse(contents)
    if not raw then
        return nil, "YAML parse error: " .. (parse_err or "unknown")
    end

    local config, val_err = validate(raw, notifier)
    if not config then return nil, val_err end

    return config, nil
end

return M
