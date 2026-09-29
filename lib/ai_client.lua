-- ai_client.lua — Google Gemini Flash HTTP client (replaces glean_client.lua)
-- Public API:
--   M.transform(text, mode, cfg, on_success, on_error)   async
--   M.test_key(api_key, callback(success, err_string))   async

local M = {}

local DEFAULT_MODEL = "gemini-flash-latest"
local API_BASE      = "https://generativelanguage.googleapis.com/v1beta/models/"

-- ── response post-processing ─────────────────────────────────────────────────

local function postprocess(text)
    text = text:match("^[\n\r%s]*(.-)[\n\r%s]*$") or text
    text = text:match("^(.-)%s*\n%-%-%-.*$") or text
    text = text:match("^[\n\r%s]*(.-)[\n\r%s]*$") or text

    local quote_pairs = {
        { '"',        '"'        },
        { "'",        "'"        },
        { "\u{201C}", "\u{201D}" },
        { "\u{2018}", "\u{2019}" },
    }
    for _, pair in ipairs(quote_pairs) do
        local open, close = pair[1], pair[2]
        if text:sub(1, #open) == open and text:sub(-(#close)) == close then
            text = text:sub(#open + 1, -(#close + 1))
            break
        end
    end
    return text
end

-- ── internal HTTP call ────────────────────────────────────────────────────────

local DEFAULT_TEMPERATURE = 0.2

local function gemini_post(api_key, model, prompt_text, timeout_s, on_success, on_error, temperature)
    local url  = API_BASE .. model .. ":generateContent"
    local body = hs.json.encode({
        contents = {
            { parts = { { text = prompt_text } } }
        },
        generationConfig = {
            temperature     = temperature or DEFAULT_TEMPERATURE,
            maxOutputTokens = 2048,
        },
    })

    local done          = false
    local timeout_timer = hs.timer.doAfter(timeout_s, function()
        if not done then
            done = true
            on_error("Request timed out after " .. timeout_s .. "s")
        end
    end)

    hs.http.asyncPost(url, body, { ["Content-Type"] = "application/json", ["X-goog-api-key"] = api_key },
        function(status, resp_body, _headers)
            if done then return end
            done = true
            if timeout_timer then timeout_timer:stop() end

            if status == 200 then
                local ok, data = pcall(hs.json.decode, resp_body)
                if ok and data
                   and data.candidates
                   and data.candidates[1]
                   and data.candidates[1].content
                   and data.candidates[1].content.parts
                   and data.candidates[1].content.parts[1] then
                    local reply = data.candidates[1].content.parts[1].text
                    if reply and reply ~= "" then
                        on_success(postprocess(reply))
                    else
                        on_error("Gemini returned an empty response")
                    end
                else
                    on_error("Unexpected response format from Gemini")
                end

            elseif status == 400 or status == 403 then
                local ok, data = pcall(hs.json.decode, resp_body)
                local msg = (ok and data and data.error and data.error.message) or ""
                if msg:find("API_KEY") or msg:find("key") or status == 403 then
                    on_error("invalid_api_key")
                else
                    on_error("Gemini API error: " .. msg)
                end

            elseif status == 429 then
                on_error("rate_limited")

            elseif status == -1 then
                on_error("No internet connection")

            else
                on_error("Gemini HTTP " .. tostring(status))
            end
        end
    )
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.transform(text, mode, cfg, on_success, on_error)
    local api_key   = cfg.gemini_api_key
    local model     = cfg.gemini_model or DEFAULT_MODEL
    local timeout_s = mode.timeout_seconds
        or (cfg.defaults and cfg.defaults.timeout_seconds)
        or 30

    if not api_key or api_key == "" then
        on_error("no_api_key")
        return
    end

    local prompt = mode.system_prompt
        .. "\n\n---\nTEXT TO TRANSFORM (verbatim, do not echo this header):\n"
        .. text

    gemini_post(api_key, model, prompt, timeout_s, on_success, on_error, mode.temperature)
end

function M.test_key(api_key, model, callback)
    -- callback(success: bool, err: string|nil)
    -- model is optional; falls back to DEFAULT_MODEL
    if type(model) == "function" then callback = model; model = nil end
    local url  = API_BASE .. (model or DEFAULT_MODEL) .. ":generateContent"
    local body = hs.json.encode({
        contents = { { parts = { { text = "Reply with the single word: OK" } } } },
        generationConfig = { maxOutputTokens = 5 },
    })

    local done = false
    local timer = hs.timer.doAfter(15, function()
        if not done then
            done = true
            callback(false, "Request timed out — check your internet connection")
        end
    end)

    hs.http.asyncPost(url, body, { ["Content-Type"] = "application/json", ["X-goog-api-key"] = api_key },
        function(status, _body, _headers)
            if done then return end
            done = true
            if timer then timer:stop() end

            if status == 200 then
                callback(true, nil)
            elseif status == 429 then
                callback(true, nil)   -- rate limited but key is valid
            elseif status == 400 or status == 403 then
                callback(false, "Invalid API key — please double-check and try again")
            elseif status == -1 then
                callback(false, "No internet connection")
            else
                callback(false, "Connection error (HTTP " .. tostring(status) .. ")")
            end
        end
    )
end

return M
