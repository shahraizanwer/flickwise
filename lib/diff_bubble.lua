-- diff_bubble.lua — "what changed" bubble + undo (IDEAS 2.1)
-- After a fix, a card above the HUD pill shows a word-level diff of the
-- original vs. the replacement. While it is visible the undo hotkey (⌘Z by
-- default) restores the original text. It auto-dismisses after
-- `duration_seconds`, with a progress bar showing time left. Hovering pauses it
-- and moving away resumes from the same point. Any other key press or a
-- click elsewhere dismisses it, because the undo is only safe right after the paste.
-- Public API:
--   M.configure(settings)                       features.diff_bubble table
--   M.show(original, result, mode_name, win, ax_ctx)  -> true if a bubble was shown
--       ax_ctx: set when the result was written through Accessibility; undo then
--       restores it the same way (the app's own ⌘Z may not know about the write)
--   M.configure_card(settings)                  features.result_card table
--   M.show_text(text, mode_name)                -> true if shown. A read-only card for
--       "show" modes (e.g. Explain Meaning): same timer, hover-to-hold, and a Copy
--       button instead of Undo. Any key or outside click dismisses it.
--   M.dismiss()
--   M.destroy()

local M = {}

local word_diff = require("flickwise.lib.word_diff")

local WIDTH        = 560
local BOTTOM_GAP   = 50     -- sits just above the HUD pill, like the picker
local MAX_RESELECT = 2000   -- chars; longer results fall back to the app's own undo
local HOVER_POLL_S = 0.1    -- mouse position is polled from Lua: a non-activating
                            -- webview doesn't reliably get mouseenter/mouseleave

local _settings = nil
local _card     = nil   -- features.result_card
local _wv       = nil
local _ready    = false
local _pending  = nil
local _tap      = nil
local _timer    = nil
local _poll     = nil
local _session  = nil   -- { kind = "diff" | "text", original, result, text, win, total, remaining, started (nil = not counting) }

local MOD_GLYPHS = { cmd = "⌘", command = "⌘", shift = "⇧", ctrl = "⌃", control = "⌃",
                     alt = "⌥", opt = "⌥", option = "⌥" }
local MOD_NAMES  = { cmd = "cmd", command = "cmd", shift = "shift", ctrl = "ctrl", control = "ctrl",
                     alt = "alt", opt = "alt", option = "alt" }

local function parse_hotkey(hk)
    local mods, key = {}, nil
    for _, part in ipairs(hk) do
        local p = tostring(part):lower()
        if MOD_NAMES[p] then mods[MOD_NAMES[p]] = true else key = p end
    end
    return mods, key
end

local function hotkey_caps(hk)
    local out = {}
    for _, p in ipairs(hk) do
        local l = tostring(p):lower()
        table.insert(out, MOD_GLYPHS[l] or l:upper())
    end
    return table.concat(out)
end

-- ── HTML ──────────────────────────────────────────────────────────────────────

local HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>
:root {
  --surface: #141416;
  --hairline: rgba(255,255,255,0.10);
  --text: #f5f5f7;
  --muted: rgba(245,245,247,0.55);
  --faint: rgba(245,245,247,0.3);
  --ok: #30d158; --ok-bg: rgba(48,209,88,0.16);
  --err: #ff6961; --err-bg: rgba(255,69,58,0.14);
  --spring: cubic-bezier(.32,1.2,.54,1);
}
html, body { margin: 0; background: transparent; overflow: hidden; }
body {
  padding: 18px 18px 8px; box-sizing: border-box;
  font: 13px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  letter-spacing: -0.01em; color: var(--text); -webkit-font-smoothing: antialiased;
  cursor: default; user-select: none;
}
#card {
  position: relative; overflow: hidden;
  background: var(--surface); border-radius: 14px;
  box-shadow: inset 0 0 0 1px var(--hairline), 0 18px 50px rgba(0,0,0,0.45), 0 2px 8px rgba(0,0,0,0.3);
  opacity: 0; transform: translateY(8px) scale(.97);
  transition: opacity .2s ease, transform .38s var(--spring);
}
#card.in { opacity: 1; transform: none; }
#head { display: flex; align-items: center; gap: 8px; padding: 11px 12px 0 14px; font-size: 12px; color: var(--muted); }
#head b { color: var(--text); font-weight: 600; }
#head .dot { width: 3px; height: 3px; border-radius: 50%; background: var(--faint); }
#x { margin-left: auto; width: 20px; height: 20px; border-radius: 6px; display: grid; place-items: center; color: var(--faint); }
#x:hover { background: rgba(255,255,255,0.08); color: var(--text); }
#diff {
  margin: 8px 14px 0; max-height: 132px; overflow-y: auto;
  font-size: 13.5px; line-height: 1.55; white-space: pre-wrap; word-wrap: break-word;
  color: rgba(245,245,247,0.78);
}
#diff::-webkit-scrollbar { width: 0; }
del { color: var(--err); background: var(--err-bg); text-decoration: line-through; text-decoration-color: rgba(255,105,97,.7);
      border-radius: 4px; padding: 0 2px; }
ins { color: var(--ok); background: var(--ok-bg); text-decoration: none; border-radius: 4px; padding: 0 2px; font-weight: 500; }
.gap { color: var(--faint); }
#diff.plain { max-height: 220px; color: var(--text); font-size: 14px; line-height: 1.5; user-select: text; }
#head .spark { color: #0a84ff; font-size: 13px; }
.row + .row { margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--hairline); }
.row .lbl { display: block; margin-bottom: 3px; font-size: 10.5px; font-weight: 600; letter-spacing: .06em;
            text-transform: uppercase; color: var(--muted); }
#foot { display: flex; align-items: center; gap: 10px; padding: 10px 12px 12px 14px; font-size: 11.5px; color: var(--faint); }
#undo {
  margin-left: auto; display: flex; align-items: center; gap: 7px;
  padding: 5px 9px 5px 10px; border-radius: 8px; color: var(--text); font-weight: 500;
  background: rgba(255,255,255,0.08); box-shadow: inset 0 0 0 1px var(--hairline);
}
#undo:hover, #copy:hover { background: rgba(255,255,255,0.14); }
#copy {
  margin-left: auto; padding: 5px 10px; border-radius: 8px; color: var(--text); font-weight: 500;
  background: rgba(255,255,255,0.08); box-shadow: inset 0 0 0 1px var(--hairline);
}
#copy.done { color: var(--ok); }
.hidden { display: none !important; }
#undo kbd { font: inherit; font-size: 11px; color: var(--muted); }
#track { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: rgba(255,255,255,0.06); }
#bar { position: absolute; left: 0; bottom: 0; height: 3px; width: 100%; background: #0a84ff;
       transform-origin: left; transform: scaleX(1); transition: background .2s ease; }
#card.held #bar { background: rgba(245,245,247,0.45); }
@keyframes drain { from { transform: scaleX(1); } to { transform: scaleX(0); } }
</style></head>
<body>
<div id="card">
  <div id="head"><span id="summary"></span><span class="dot"></span><span id="mode"></span>
    <span id="x" title="Dismiss">✕</span></div>
  <div id="diff"></div>
  <div id="foot"><span id="hint">Original restored with undo</span>
    <span id="undo">Undo <kbd id="keys"></kbd></span><span id="copy" class="hidden">Copy</span></div>
  <div id="track"></div><div id="bar"></div>
</div>
<script>
const post = (m) => window.webkit.messageHandlers.bubble.postMessage(m);
const card = document.getElementById('card');
function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }
function vis(s) {   // whitespace-only edits would be invisible; show a marker
  if (!/^\s+$/.test(s)) return esc(s);
  return s.indexOf('\n') >= 0 ? '↵' : '␣';
}
function render(d) {
  card.classList.remove('in');
  const text = d.kind === 'text', body = document.getElementById('diff');
  document.getElementById('mode').textContent = d.mode;
  document.getElementById('hint').textContent = d.hint;
  document.getElementById('undo').classList.toggle('hidden', text);
  const copy = document.getElementById('copy');
  copy.classList.toggle('hidden', !text); copy.classList.remove('done'); copy.textContent = 'Copy';
  body.classList.toggle('plain', text);
  body.scrollTop = 0;
  if (text) {
    document.getElementById('summary').innerHTML = '<span class="spark">✦</span> <b>' + esc(d.title) + '</b>';
    body.innerHTML = rows(d.text);
  } else {
  document.getElementById('summary').innerHTML = '<b>' + d.changes + '</b> ' + (d.changes === 1 ? 'change' : 'changes');
  document.getElementById('keys').textContent = d.keys;
  body.innerHTML = d.segs.map(function(s) {
    if (s.op === 'del') return '<del>' + vis(s.text) + '</del>';
    if (s.op === 'ins') return '<ins>' + vis(s.text) + '</ins>';
    if (s.op === 'gap') return '<span class="gap"> … </span>';
    return esc(s.text);
  }).join('');
  }
  hint = d.hint;
  countdown(d.duration, d.duration, false);
  // Report size synchronously: the window is still hidden here, and hidden
  // webviews never fire requestAnimationFrame. Lua calls enter() once shown.
  post({ action: 'size', h: Math.ceil(document.body.scrollHeight) });
}
// Progress bar at `remaining` of `total` seconds; a negative delay starts the
// animation part-way through, so pausing and resuming never makes it jump.
let hint = '';
function countdown(remaining, total, running) {
  const bar = document.getElementById('bar');
  bar.style.animation = 'none'; void bar.offsetWidth;
  bar.style.animation = 'drain ' + total + 's linear ' + (remaining - total) + 's forwards';
  bar.style.animationPlayState = running ? 'running' : 'paused';
  card.classList.toggle('held', !running && remaining < total);
  document.getElementById('hint').textContent = card.classList.contains('held')
    ? 'Paused while you read · move away to continue' : hint;
}
function enter() { requestAnimationFrame(function() { card.classList.add('in'); }); }
function leave() { card.classList.remove('in'); }
// "Label: text" lines (e.g. "Meaning: …" / "Roman Urdu: …") become labeled rows;
// anything else continues the current row as plain text.
function rows(text) {
  const out = [];
  String(text || '').split('\n').forEach(function(line) {
    const m = line.match(/^\s*\**([A-Za-z][A-Za-z ]{0,24}?)\**\s*:\s*(.*)$/);
    if (m) out.push({ label: m[1].trim(), body: m[2] });
    else if (out.length) out[out.length - 1].body += (line.trim() ? '\n' + line : '');
    else if (line.trim()) out.push({ label: '', body: line });
  });
  return out.map(function(r) {
    return '<div class="row">' + (r.label ? '<span class="lbl">' + esc(r.label) + '</span>' : '')
      + esc(r.body.trim()) + '</div>';
  }).join('');
}
document.getElementById('undo').addEventListener('mousedown', function() { post({ action: 'undo' }); });
document.getElementById('copy').addEventListener('mousedown', function() { post({ action: 'copy' }); });
function copied() { const c = document.getElementById('copy'); c.textContent = 'Copied ✓'; c.classList.add('done'); }
document.getElementById('x').addEventListener('mousedown', function() { post({ action: 'close' }); });
</script>
</body></html>]]

-- ── helpers ───────────────────────────────────────────────────────────────────

local function js(code)
    if not _wv then return end
    if not _ready then _pending = code; return end
    _wv:evaluateJavaScript(code)
end

local function stop_timer()
    if _timer then _timer:stop(); _timer = nil end
end

local function stop_tap()
    if _tap then _tap:stop(); _tap = nil end
end

local function frame_for(h)
    local vf = hs.screen.mainScreen():frame()
    return {
        x = math.floor(vf.x + (vf.w - WIDTH) / 2),
        y = math.floor(vf.y + vf.h - BOTTOM_GAP - h),
        w = WIDTH, h = h,
    }
end

-- A token counts as a word if it has any letter/digit (incl. non-ASCII bytes).
local function is_word(t) return t:match("[^%s%p]") ~= nil end

-- Collapse long unchanged stretches to a few words of context around each edit.
local function trim_context(segs, ctx)
    local out = {}
    for i, s in ipairs(segs) do
        if s.op ~= "eq" then
            table.insert(out, s)
        else
            local toks = word_diff.tokenize(s.text)
            local words = 0
            for _, t in ipairs(toks) do if is_word(t) then words = words + 1 end end
            local keep_head = (i > 1) and ctx or 0            -- after a change
            local keep_tail = (i < #segs) and ctx or 0        -- before a change
            if words <= keep_head + keep_tail + 2 then
                table.insert(out, s)
            else
                local function take(from, to, step, limit)
                    local acc, seen = {}, 0
                    for k = from, to, step do
                        local t = toks[k]
                        if is_word(t) then
                            if seen == limit then break end
                            seen = seen + 1
                        end
                        table.insert(acc, t)
                    end
                    return acc
                end
                if keep_head > 0 then
                    local head = take(1, #toks, 1, keep_head)
                    local text = table.concat(head):gsub("%s+$", "")
                    table.insert(out, { op = "eq", text = text })
                end
                table.insert(out, { op = "gap" })
                if keep_tail > 0 then
                    local tail = take(#toks, 1, -1, keep_tail)
                    local rev = {}
                    for k = #tail, 1, -1 do table.insert(rev, tail[k]) end
                    -- Start the context at a word, not at leftover punctuation.
                    local text = table.concat(rev):gsub("^[%s%p]+", "")
                    table.insert(out, { op = "eq", text = text })
                end
            end
        end
    end
    return out
end

-- ── countdown (auto-dismiss, paused while hovered) ────────────────────────────

local function countdown_js(running)
    js(string.format("countdown(%.3f, %.3f, %s)",
        _session.remaining, _session.total, running and "true" or "false"))
end

local function resume_countdown()
    stop_timer()
    if not _session then return end
    _session.started = hs.timer.secondsSinceEpoch()
    countdown_js(true)
    _timer = hs.timer.doAfter(math.max(0.05, _session.remaining), function()
        _timer = nil
        M.dismiss()
    end)
end

local function pause_countdown()
    if not (_session and _session.started) then return end
    local elapsed = hs.timer.secondsSinceEpoch() - _session.started
    _session.remaining = math.max(0, _session.remaining - elapsed)
    _session.started = nil
    stop_timer()
    countdown_js(false)
end

-- The card inside the window (body padding: 18px top/sides, 8px bottom).
local function mouse_over_card()
    if not _wv then return false end
    local p, f = hs.mouse.absolutePosition(), _wv:frame()
    return p.x >= f.x + 18 and p.x <= f.x + f.w - 18 and p.y >= f.y + 18 and p.y <= f.y + f.h - 8
end

local function stop_poll()
    if _poll then _poll:stop(); _poll = nil end
end

local function start_poll()
    stop_poll()
    _poll = hs.timer.doEvery(HOVER_POLL_S, function()
        if not _session then stop_poll(); return end
        local over = mouse_over_card()
        if over and _session.started then pause_countdown()
        elseif not over and not _session.started then resume_countdown() end
    end)
end

local function same_window(win)
    local now = hs.window.focusedWindow()
    return win and now and now:id() == win:id()
end

-- ── undo ──────────────────────────────────────────────────────────────────────

local function reselect_and_paste(s)
    local n = utf8.len(s.result) or #s.result
    for _ = 1, n do hs.eventtap.keyStroke({ "shift" }, "left", 1000) end
    local saved = hs.pasteboard.getContents()
    hs.pasteboard.setContents(s.original)
    hs.eventtap.keyStroke({ "cmd" }, "v", 1000)
    hs.timer.usleep(150000)
    if saved then hs.pasteboard.setContents(saved) end
end

-- `passthrough`: the user's own ⌘Z is already on its way to the app.
local function undo(passthrough)
    local s = _session
    if not s then return end
    local notifier = require("flickwise.lib.notifier")
    local hud      = require("flickwise.lib.hud")
    M.dismiss()   -- stops the tap first, so our synthetic keys aren't seen by it

    if passthrough then
        hud.info("Restored original")
        notifier.log("Undo via app ⌘Z (passthrough)")
        return
    end

    if s.ax then
        local ok, why = require("flickwise.lib.ax_text").restore(s.ax)
        if ok then
            hud.info("Restored original")
            notifier.log("Undo via Accessibility")
        else
            hs.pasteboard.setContents(s.original)
            hud.error("Couldn't undo (" .. tostring(why) .. ") — original copied to clipboard")
            notifier.log("Undo via Accessibility failed: " .. tostring(why))
        end
        return
    end

    -- A click on the bubble can pull focus to Hammerspoon; hand it back first.
    if s.win and not same_window(s.win) then pcall(function() s.win:focus() end) end
    hs.timer.doAfter(0.08, function()
        if s.win and not same_window(s.win) then
            hud.error("Can't undo — the original window isn't focused")
            return
        end
        local method = _settings.undo_method
        if method == "reselect" and (utf8.len(s.result) or #s.result) > MAX_RESELECT then
            method = "app"
        end
        if method == "reselect" then
            reselect_and_paste(s)
        else
            hs.eventtap.keyStroke({ "cmd" }, "z", 1000)
        end
        hud.info("Restored original")
        notifier.log("Undo via " .. method)
    end)
end

-- ── event tap (only alive while the bubble is visible) ────────────────────────

local function on_event(e)
    if not _session then return false end
    local t = e:getType()

    if t == hs.eventtap.event.types.leftMouseDown then
        local p = hs.mouse.absolutePosition()
        local f = _wv and _wv:frame()
        if not f or p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then
            M.dismiss()
        end
        return false
    end

    -- Read-only card: nothing to undo, so any key just closes it (and goes through).
    if _session.kind == "text" then
        M.dismiss()
        return false
    end

    local mods, key = parse_hotkey(_settings.undo_hotkey)
    local flags = e:getFlags()
    local match = key and e:getKeyCode() == hs.keycodes.map[key]
    if match then
        for _, m in ipairs({ "cmd", "shift", "ctrl", "alt" }) do
            if (flags[m] or false) ~= (mods[m] or false) then match = false; break end
        end
    end

    if not match then
        M.dismiss()          -- user kept typing; the undo would no longer be ours
        return false
    end
    if not same_window(_session.win) then
        M.dismiss()
        return false
    end

    -- ⌘Z + "app" method: let the app's own undo handle it, just close the bubble.
    -- Not for direct (Accessibility) replacements: those are undone the same way.
    local passthrough = not _session.ax and _settings.undo_method == "app" and mods.cmd and key == "z"
        and not (mods.shift or mods.ctrl or mods.alt)
    undo(passthrough)
    return not passthrough
end

local function start_tap()
    stop_tap()
    _tap = hs.eventtap.new(
        { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.leftMouseDown },
        function(e)
            local ok, res = xpcall(on_event, debug.traceback, e)
            if not ok then
                require("flickwise.lib.notifier").log("Diff bubble error: " .. tostring(res))
                M.dismiss()
                return false
            end
            return res
        end)
    _tap:start()
end

-- ── webview ───────────────────────────────────────────────────────────────────

local function build_webview()
    local uc = hs.webview.usercontent.new("bubble")
    uc:setCallback(function(msg)
        local d = msg.body
        if type(d) ~= "table" or not _session then return end
        if d.action == "size" then
            _wv:frame(frame_for(math.max(80, tonumber(d.h) or 160)))
            _wv:show()
            _wv:evaluateJavaScript("enter()")
            -- The countdown starts once the bubble is actually on screen
            -- (dismiss() stops the poll, so no poll = a fresh bubble).
            if not _poll then
                if mouse_over_card() then countdown_js(false) else resume_countdown() end
                start_poll()
            end
        elseif d.action == "undo" then
            undo(false)
        elseif d.action == "copy" and _session.kind == "text" then
            hs.pasteboard.setContents(_session.text)
            _wv:evaluateJavaScript("copied()")
        elseif d.action == "close" then
            M.dismiss()
        end
    end)
    _wv = hs.webview.new(frame_for(160), { developerExtrasEnabled = false }, uc)
    _wv:windowStyle({ "borderless", "nonactivating" })
    _wv:transparent(true)
    _wv:shadow(false)
    _wv:allowTextEntry(false)
    _wv:level(hs.drawing.windowLevels.popUpMenu)
    _wv:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary", "ignoresCycle" })
    _wv:navigationCallback(function(action)
        if action == "didFinishNavigation" then
            _ready = true
            if _pending then
                local code = _pending
                _pending = nil
                _wv:evaluateJavaScript(code)
            end
        end
    end)
    _wv:html(HTML)
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.configure(settings)
    _settings = settings
    M.destroy()   -- rebuilt lazily on the next show
end

function M.configure_card(settings)
    _card = settings
end

function M.show_text(text, mode_name)
    if not (_card and _card.enabled) then return false end
    M.dismiss()
    if not _wv then build_webview() end
    _session = { kind = "text", text = text, total = _card.duration_seconds, remaining = _card.duration_seconds }
    js("render(" .. hs.json.encode({
        kind     = "text",
        title    = mode_name or "",
        mode     = "your text wasn't changed",
        text     = text,
        hint     = "Hover to keep it open",
        duration = _card.duration_seconds,
    }) .. ")")
    start_tap()
    return true
end

function M.show(original, result, mode_name, win, ax_ctx)
    if not (_settings and _settings.enabled) then return false end
    M.dismiss()

    local segs, stats = word_diff.diff(original, result)
    if stats.changes == 0 then return false end

    if not _wv then build_webview() end
    _session = { kind = "diff", original = original, result = result, win = win, ax = ax_ctx,
                 total = _settings.duration_seconds, remaining = _settings.duration_seconds }

    local keys = hotkey_caps(_settings.undo_hotkey)
    local data = {
        kind     = "diff",
        segs     = trim_context(segs, _settings.context_words),
        changes  = stats.changes,
        mode     = mode_name or "",
        keys     = keys,
        hint     = "Any other key keeps the change",
        duration = _settings.duration_seconds,
    }
    js("render(" .. hs.json.encode(data) .. ")")
    start_tap()
    return true
end

function M.dismiss()
    stop_timer()
    stop_poll()
    stop_tap()
    if not _session then return end
    _session = nil
    if _wv then
        js("leave()")
        _wv:hide(0.15)
    end
end

function M.destroy()
    M.dismiss()
    if _wv then _wv:delete(); _wv = nil end
    _ready, _pending = false, nil
end

return M
