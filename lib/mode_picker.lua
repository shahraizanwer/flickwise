-- mode_picker.lua — floating command palette to pick a mode without memorising hotkeys
-- Opens just above the HUD pill. Keyboard is read with an eventtap so focus never
-- leaves the app you're typing in: ↑↓ / ⌃N ⌃P move, ↵ applies, 1–9 jump, esc closes,
-- typing filters.
-- Public API: M.setup(config), M.teardown()

local M = {}

local _hotkey = nil
local _wv     = nil
local _tap    = nil
local _config = nil
local _timer  = nil   -- keep a reference so the timer isn't garbage-collected

-- Open-picker session state
local _session = nil   -- { text, original, win, query, sel, items }

local WIDTH      = 400
local ROW_H      = 40
local CHROME_H   = 118   -- header + search + footer + card padding/margins
local BOTTOM_GAP = 50    -- sits just above the HUD pill

local MOD_GLYPHS = {
    cmd = "⌘", command = "⌘",
    shift = "⇧",
    ctrl = "⌃", control = "⌃",
    alt = "⌥", opt = "⌥", option = "⌥",
}

local function hotkey_caps(hk)
    local caps = {}
    if not hk then return caps end
    for _, p in ipairs(hk) do
        table.insert(caps, MOD_GLYPHS[p:lower()] or p:upper())
    end
    return caps
end

local function parse_hotkey(hk)
    local mods, key = {}, nil
    for _, part in ipairs(hk) do
        local p = part:lower()
        if     p == "cmd" or p == "command"              then table.insert(mods, "cmd")
        elseif p == "shift"                              then table.insert(mods, "shift")
        elseif p == "ctrl" or p == "control"             then table.insert(mods, "ctrl")
        elseif p == "alt"  or p == "opt" or p == "option" then table.insert(mods, "alt")
        else   key = p
        end
    end
    return mods, key
end

-- ── HTML ──────────────────────────────────────────────────────────────────────

local HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>
:root {
  --surface: #141416;
  --hairline: rgba(255,255,255,0.10);
  --text: #f5f5f7;
  --muted: rgba(245,245,247,0.5);
  --faint: rgba(245,245,247,0.28);
  --sel: rgba(255,255,255,0.08);
  --spring: cubic-bezier(.32,1.2,.54,1);
}
html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
body {
  display: flex; align-items: flex-end; justify-content: center;
  padding: 18px 18px 8px; box-sizing: border-box;
  font: 13px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  letter-spacing: -0.01em; color: var(--text); -webkit-font-smoothing: antialiased;
  cursor: default; user-select: none;
}
#card {
  width: 100%; background: var(--surface); border-radius: 16px;
  box-shadow: inset 0 0 0 1px var(--hairline), 0 18px 50px rgba(0,0,0,0.45), 0 2px 8px rgba(0,0,0,0.3);
  padding: 6px; box-sizing: border-box;
}
#snippet {
  padding: 10px 10px 8px; color: var(--muted); font-size: 12px;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
#snippet b { color: var(--faint); font-weight: 500; margin-right: 6px; }
#search {
  display: flex; align-items: center; gap: 8px; margin: 0 4px 6px; padding: 8px 8px;
  border-bottom: 1px solid var(--hairline); font-size: 14px;
}
#search svg { width: 14px; height: 14px; flex: none; stroke: var(--faint); fill: none; stroke-width: 1.8; stroke-linecap: round; }
#q { color: var(--text); }
#q:empty::before { content: attr(data-ph); color: var(--faint); }
#caret { width: 1.5px; height: 16px; background: #0a84ff; margin-left: -6px; animation: blink 1s steps(1) infinite; }
@keyframes blink { 50% { opacity: 0; } }
#list { display: flex; flex-direction: column; }
.row {
  height: ]] .. ROW_H .. [[px; display: flex; align-items: center; gap: 10px;
  padding: 0 10px; border-radius: 9px; box-sizing: border-box;
}
.row.sel { background: var(--sel); }
.num {
  width: 18px; height: 18px; border-radius: 5px; font-size: 11px; font-weight: 600;
  display: grid; place-items: center; color: var(--muted);
  background: rgba(255,255,255,0.06); font-variant-numeric: tabular-nums; flex: none;
}
.row.sel .num { background: #0a84ff; color: #fff; }
.name { flex: 1; font-size: 13.5px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row:not(.sel) .name { color: rgba(245,245,247,0.82); }
.keys { display: flex; gap: 3px; }
.keys span {
  min-width: 18px; height: 18px; padding: 0 4px; box-sizing: border-box; border-radius: 5px;
  display: grid; place-items: center; font-size: 11px; color: var(--muted);
  box-shadow: inset 0 0 0 1px var(--hairline);
}
.empty { padding: 14px 10px; color: var(--faint); }
#foot {
  display: flex; gap: 14px; padding: 9px 10px 5px; margin-top: 4px;
  border-top: 1px solid var(--hairline); color: var(--faint); font-size: 11px;
}
#foot kbd { font: inherit; color: var(--muted); margin-right: 3px; }
</style></head>
<body>
<div id="card">
  <div id="snippet"></div>
  <div id="search">
    <svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.8"/><path d="M10.6 10.6L14 14"/></svg>
    <span id="q" data-ph="Transform selection…"></span><span id="caret"></span>
  </div>
  <div id="list"></div>
  <div id="foot">
    <span><kbd>↑↓</kbd>navigate</span><span><kbd>↵</kbd>apply</span>
    <span><kbd>1–9</kbd>quick pick</span><span style="margin-left:auto"><kbd>esc</kbd>close</span>
  </div>
</div>
<script>
const card = document.getElementById('card');
const list = document.getElementById('list');
function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }
function render(s) {
  document.getElementById('snippet').innerHTML = s.snippet ? '<b>Selection</b>' + esc(s.snippet) : '';
  document.getElementById('q').textContent = s.query;
  if (!s.items.length) {
    list.innerHTML = '<div class="empty">No matching modes</div>';
  } else {
    list.innerHTML = s.items.map(function(it, i) {
      return '<div class="row' + (i === s.sel ? ' sel' : '') + '" data-i="' + i + '">'
        + '<span class="num">' + (i < 9 ? i + 1 : '') + '</span>'
        + '<span class="name">' + esc(it.name) + '</span>'
        + '<span class="keys">' + it.keys.map(function(k) { return '<span>' + esc(k) + '</span>'; }).join('') + '</span>'
        + '</div>';
    }).join('');
  }
}
list.addEventListener('mousedown', function(e) {
  const row = e.target.closest('.row');
  if (row) window.webkit.messageHandlers.picker.postMessage({ action: 'choose', index: +row.dataset.i });
});
list.addEventListener('mousemove', function(e) {
  const row = e.target.closest('.row');
  if (row && !row.classList.contains('sel'))
    window.webkit.messageHandlers.picker.postMessage({ action: 'hover', index: +row.dataset.i });
});
</script>
</body></html>]]

-- ── rendering ─────────────────────────────────────────────────────────────────

local function snippet_of(text)
    local s = (text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #s > 140 then s = s:sub(1, 140) .. "…" end
    return s
end

local function filtered_items(query)
    local out = {}
    local q = query:lower()
    for _, mode in ipairs(_config.modes) do
        if q == "" or mode.name:lower():find(q, 1, true) then
            table.insert(out, mode)
        end
    end
    return out
end

local function frame_for(n_rows)
    local vf = hs.screen.mainScreen():frame()
    local h  = CHROME_H + math.max(n_rows, 1) * ROW_H
    return {
        x = math.floor(vf.x + (vf.w - WIDTH) / 2),
        y = math.floor(vf.y + vf.h - BOTTOM_GAP - h),
        w = WIDTH,
        h = h,
    }
end

local function render()
    if not (_wv and _session) then return end
    local items = {}
    for _, mode in ipairs(_session.items) do
        table.insert(items, { name = mode.name, keys = hotkey_caps(mode.hotkey) })
    end
    local payload = hs.json.encode({
        snippet = snippet_of(_session.text),
        query   = _session.query,
        items   = items,
        sel     = _session.sel - 1,
    })
    _wv:evaluateJavaScript("render(" .. payload .. ")")
end

local function refilter()
    _session.items = filtered_items(_session.query)
    if _session.sel > #_session.items then _session.sel = math.max(#_session.items, 1) end
    if _session.sel < 1 then _session.sel = 1 end
    render()
end

-- ── open / close ──────────────────────────────────────────────────────────────

local function stop_tap()
    if _tap then pcall(function() _tap:stop() end); _tap = nil end
end

local function close(restore_clipboard)
    stop_tap()
    local s = _session
    _session = nil
    if _wv then _wv:hide(0.12) end
    if restore_clipboard and s and s.original then
        hs.pasteboard.setContents(s.original)
    end
    return s
end

local function choose(index)
    if not _session then return end
    local mode = _session.items[index]
    if not mode then return end
    local s = close(false)
    local text_replacer = require("flickwise.lib.text_replacer")
    -- A mouse click can pull focus to Hammerspoon; hand it back before pasting.
    if s.win and hs.window.focusedWindow() ~= s.win then pcall(function() s.win:focus() end) end
    if _timer then _timer:stop() end
    _timer = hs.timer.doAfter(0.08, function()
        _timer = nil
        text_replacer.run_with_text(s.text, s.original, mode, _config)
    end)
end

local KC = hs.keycodes.map

local function on_event(e)
    if not _session then return false end
    local t = e:getType()

    if t == hs.eventtap.event.types.leftMouseDown then
        local p = hs.mouse.absolutePosition()
        local f = _wv and _wv:frame()
        if not f or p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then
            close(true)
        end
        return false
    end

    local code  = e:getKeyCode()
    local flags = e:getFlags()

    if code == KC.escape then close(true); return true end
    if code == KC["return"] or code == KC.padenter then choose(_session.sel); return true end

    local n = #_session.items
    local function move(d)
        if n > 0 then _session.sel = ((_session.sel - 1 + d) % n) + 1; render() end
    end
    if code == KC.down or (flags.ctrl and (code == KC.n or code == KC.j)) or (code == KC.tab and not flags.shift) then
        move(1); return true
    end
    if code == KC.up or (flags.ctrl and (code == KC.p or code == KC.k)) or (code == KC.tab and flags.shift) then
        move(-1); return true
    end
    if code == KC.delete then
        if flags.alt or flags.cmd then _session.query = "" else _session.query = _session.query:sub(1, -2) end
        refilter()
        return true
    end
    if flags.cmd or flags.ctrl then return true end   -- swallow, never leak to the app

    local ch = e:getCharacters(true) or ""
    if _session.query == "" and ch:match("^[1-9]$") then
        choose(tonumber(ch)); return true
    end
    if #ch == 1 and ch:match("[%w%p ]") then
        _session.query = _session.query .. ch
        _session.sel = 1
        refilter()
    end
    return true
end

local function open(text, original, win)
    _session = { text = text, original = original, win = win, query = "", sel = 1 }
    _session.items = filtered_items("")

    _wv:frame(frame_for(#_config.modes))
    render()
    _wv:show(0.12)

    stop_tap()
    _tap = hs.eventtap.new(
        { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.leftMouseDown },
        function(e)
            local ok, res = xpcall(on_event, debug.traceback, e)
            if not ok then
                require("flickwise.lib.notifier").log("Picker error: " .. tostring(res))
                close(true)
                return false
            end
            return res
        end)
    _tap:start()
end

local function build_webview()
    local uc = hs.webview.usercontent.new("picker")
    uc:setCallback(function(msg)
        local d = msg.body
        if type(d) ~= "table" or not _session then return end
        if d.action == "choose" then
            choose((d.index or 0) + 1)
        elseif d.action == "hover" then
            _session.sel = (d.index or 0) + 1
            render()
        end
    end)
    _wv = hs.webview.new(frame_for(1), { developerExtrasEnabled = false }, uc)
    _wv:windowStyle({ "borderless", "nonactivating" })
    _wv:transparent(true)
    _wv:shadow(false)
    _wv:allowTextEntry(false)
    _wv:level(hs.drawing.windowLevels.popUpMenu)
    _wv:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary", "ignoresCycle" })
    _wv:html(HTML)
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.setup(config)
    M.teardown()
    _config = config

    if not config.picker_hotkey then return end

    local notifier      = require("flickwise.lib.notifier")
    local hud           = require("flickwise.lib.hud")
    local text_replacer = require("flickwise.lib.text_replacer")

    build_webview()

    local mods, key = parse_hotkey(config.picker_hotkey)
    if not key then
        notifier.log("WARNING: mode picker hotkey has no non-modifier key — skipped")
        return
    end

    local ok, hk = pcall(hs.hotkey.bind, mods, key, function()
        if _session then close(true); return end   -- same hotkey toggles it shut
        if text_replacer.is_in_flight() then
            hud.info("Still working on the last one…")
            return
        end

        local win = hs.window.focusedWindow()
        local front_app = hs.application.frontmostApplication()
        notifier.log("Picker triggered — front app: " .. (front_app and front_app:name() or "nil"))

        local original = hs.pasteboard.getContents()
        hs.timer.usleep(100000)
        hs.eventtap.keyStroke({"cmd"}, "c")

        -- Poll up to 2.5s for the clipboard to be populated
        local deadline = hs.timer.secondsSinceEpoch() + 2.5
        local text, attempts = nil, 0
        repeat
            hs.timer.usleep(150000)
            local t = hs.pasteboard.getContents()
            attempts = attempts + 1
            if t and t ~= "" and t ~= original then
                text = t
                notifier.debug("Picker: captured on attempt " .. attempts)
                break
            end
        until hs.timer.secondsSinceEpoch() >= deadline

        notifier.log("Picker: clipboard after Cmd+C: len=" .. tostring(text and #text or 0) .. " (attempts: " .. attempts .. ")")

        if not text then
            hud.error("Select some text first")
            notifier.log("ERROR: Could not capture clipboard. Hammerspoon may need accessibility permissions.")
            if original then hs.pasteboard.setContents(original) end
            return
        end

        open(text, original, win)
    end)
    if ok and hk then
        _hotkey = hk
        notifier.log("Mode picker bound to " .. table.concat(config.picker_hotkey, "+"))
    else
        notifier.log("WARNING: mode picker hotkey bind failed (conflict?): " .. tostring(hk))
    end
end

function M.teardown()
    if _session then close(true) end
    stop_tap()
    if _hotkey then
        pcall(function() _hotkey:delete() end)
        _hotkey = nil
    end
    if _wv then
        pcall(function() _wv:delete() end)
        _wv = nil
    end
end
return M
