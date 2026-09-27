-- glean_client.lua — Glean CLI wrapper
-- Public API:
--   M.is_available(cfg)                                   -> bool, err_string
--   M.transform(text, mode, cfg, on_success, on_error)    -- async via hs.task
--
-- glean chat v0.17.0 behavior (verified):
--   stdout  = plain text reply
--   flags   = --no-save not supported; use --json with saveChat=false instead
--             FAST mode: {agent="FAST", mode="DEFAULT"} — NOT {agent="DEFAULT", mode="FAST"}
--   timeout = managed here via hs.timer + task:terminate()

local M = {}

-- ── response post-processing ─────────────────────────────────────────────────

-- Strip outer whitespace/newlines, trailing "---" separators + follow-up questions,
-- then one surrounding quote pair if present.
local function postprocess(text)
    text = text:match("^[\n\r%s]*(.-)[\n\r%s]*$") or text

    -- Remove anything from a trailing "---" onward (model follow-up noise)
    text = text:match("^(.-)%s*\n%-%-%-.*$") or text

    text = text:match("^[\n\r%s]*(.-)[\n\r%s]*$") or text

    local quote_pairs = {
        { '"',        '"'        },
        { "'",        "'"        },
        { "\u{201C}", "\u{201D}" },  -- " "
        { "\u{2018}", "\u{2019}" },  -- ' '
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

-- ── public API ────────────────────────────────────────────────────────────────

-- is_available(cfg) -> bool, err_string
-- Checks (1) binary exists, (2) glean auth status exits clean.
function M.is_available(cfg)
    local bin = cfg and cfg.glean_binary_path or "/opt/homebrew/bin/glean"

    local f = io.open(bin, "r")
    if not f then
        return false, "Glean CLI not installed at " .. bin
    end
    f:close()

    local output = hs.execute(bin .. " auth status 2>&1") or ""
    if output:find("Not configured") or output:find("not authenticated") or output:find("Error") then
        return false, "Glean not authenticated — run: glean auth login"
    end

    return true, nil
end

-- transform(text, mode, cfg, on_success, on_error)
-- Async — uses hs.task so the UI thread is never blocked.
-- Timeout is enforced via hs.timer + task:terminate().
function M.transform(text, mode, cfg, on_success, on_error)
    local notifier  = require("flickwise.lib.notifier")
    local bin       = cfg.glean_binary_path or "/opt/homebrew/bin/glean"
    local timeout_s = mode.timeout_seconds or (cfg.defaults and cfg.defaults.timeout_seconds) or 30

    -- Build combined prompt: system instructions + delimiter + user text
    local combined = mode.system_prompt
        .. "\n\n---\nTEXT TO TRANSFORM (verbatim, do not echo this header):\n"
        .. text

    -- agent="FAST" mode="DEFAULT" matches desktop app Fast mode (agent="DEFAULT" mode="FAST" returns empty)
    local json_body = hs.json.encode({
        messages    = {{ author = "USER", messageType = "CONTENT", fragments = {{ text = combined }} }},
        saveChat    = false,
        agentConfig = { agent = "FAST", mode = "DEFAULT" },
    })

    notifier.debug("glean transform: bin=" .. bin .. " timeout=" .. timeout_s .. "s")
    notifier.debug("Prompt length: " .. #combined)

    local done          = false
    local timeout_timer = nil

    local task = hs.task.new(bin,
        function(exit_code, stdout, stderr)
            if done then return end
            done = true
            if timeout_timer then timeout_timer:stop() end

            notifier.debug("glean exit=" .. tostring(exit_code)
                .. " stdout_len=" .. #(stdout or ""))

            if exit_code ~= 0 then
                local err_msg = stderr or stdout or "unknown error"
                if err_msg:find("auth") or err_msg:find("token") or err_msg:find("401") then
                    on_error("Glean auth expired — run: glean auth login")
                else
                    on_error("glean chat failed (exit " .. tostring(exit_code) .. "): "
                        .. (err_msg:match("^%s*(.-)%s*$") or err_msg))
                end
                return
            end

            -- stdout is plain text from v0.17.0
            local reply = (stdout or ""):match("^%s*(.-)%s*$")
            if not reply or reply == "" then
                notifier.log("Empty stdout from glean chat")
                on_error("Glean returned empty response")
                return
            end

            reply = postprocess(reply)
            if reply == "" then
                on_error("Glean returned empty response after post-processing")
                return
            end

            notifier.debug("Reply (" .. #reply .. " chars): " .. reply:sub(1, 100))
            on_success(reply)
        end,
        { "chat", "--json", json_body }
    )

    if not task then
        on_error("Failed to start glean task — check binary path: " .. bin)
        return
    end

    -- Enforce timeout via timer
    timeout_timer = hs.timer.doAfter(timeout_s, function()
        if not done then
            done = true
            pcall(function() task:terminate() end)
            notifier.log("glean chat timed out after " .. timeout_s .. "s")
            on_error(string.format("Request timed out after %ds", timeout_s))
        end
    end)

    task:start()
end

return M
