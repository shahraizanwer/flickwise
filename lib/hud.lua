-- hud.lua — Wispr-style floating pill at the bottom-center of the screen
-- Replaces hs.alert for all run-time feedback (working / done / error).
-- Public API:
--   M.init()                       create the (hidden) pill window
--   M.working(label)               expanding pill with animated waveform
--   M.success(label, detail)       green check, collapses after a moment
--   M.error(msg)                   red state, collapses after a moment
--   M.info(msg)                    neutral message, collapses after a moment
--   M.configure(settings)          features.idle_pill table from config.yaml
--   M.idle_visible()               whether the resting pill is enabled
--   M.destroy()

local M = {}

-- Window sizes: large while a message is showing, tiny while resting.
-- The pill itself is drawn bottom-centered inside the window, so resizing
-- the window never moves it on screen.
local ACTIVE_SIZE = { w = 560, h = 64 }
local IDLE_SIZE   = { w = 80,  h = 26 }

local HOLD = { success = 1.3, info = 1.8, error = 3.5 }
local COLLAPSE_S = 0.45

local _wv         = nil
local _ready      = false
local _pending    = nil
local _timer      = nil
local _size       = nil
local _state      = "hidden"
local _idle       = false   -- features.idle_pill.enabled (config.yaml)

local function idle_enabled()
    return _idle
end

local function frame_for(size)
    local vf = hs.screen.mainScreen():frame()
    return {
        x = math.floor(vf.x + (vf.w - size.w) / 2),
        y = math.floor(vf.y + vf.h - size.h),
        w = size.w,
        h = size.h,
    }
end

local function set_size(size)
    if not _wv then return end
    _size = size
    _wv:frame(frame_for(size))
end

local function js(code)
    if not _wv then return end
    if not _ready then _pending = code; return end
    _wv:evaluateJavaScript(code)
end

local function cancel_timer()
    if _timer then _timer:stop(); _timer = nil end
end

local HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>
:root {
  --surface: rgba(16,16,18,0.94);
  --surface-idle: rgba(16,16,18,0.62);
  --hairline: rgba(255,255,255,0.12);
  --text: #f5f5f7;
  --muted: rgba(245,245,247,0.55);
  --ok: #30d158;
  --err: #ff453a;
  --spring: cubic-bezier(.32,1.28,.54,1);
}
html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
body {
  display: flex; align-items: flex-end; justify-content: center;
  padding-bottom: 10px; box-sizing: border-box;
  font: 500 13px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  letter-spacing: -0.01em; -webkit-font-smoothing: antialiased;
  cursor: default; user-select: none;
}
#pill {
  position: relative;
  width: 38px; height: 8px; border-radius: 999px;
  background: var(--surface-idle);
  box-shadow: inset 0 0 0 1px var(--hairline), 0 4px 14px rgba(0,0,0,0.28);
  display: flex; align-items: center; justify-content: center; overflow: hidden;
  opacity: 0; transform: translateY(6px) scale(0.9);
  transition: width .42s var(--spring), height .42s var(--spring),
              background .25s ease, opacity .25s ease, transform .42s var(--spring);
}
#pill.idle   { opacity: 1; transform: none; }
#pill.active { opacity: 1; transform: none; height: 36px; background: var(--surface);
               box-shadow: inset 0 0 0 1px var(--hairline), 0 10px 30px rgba(0,0,0,0.38); }
#content {
  position: absolute; left: 0; top: 0; bottom: 0;
  display: flex; align-items: center; gap: 10px;
  padding: 0 16px 0 13px; white-space: nowrap; color: var(--text);
  opacity: 0; transition: opacity .18s ease;
}
#pill.active #content { opacity: 1; transition-delay: .1s; }

/* waveform */
.bars { display: flex; align-items: center; gap: 2.5px; height: 16px; }
.bars i {
  display: block; width: 3px; height: 16px; border-radius: 2px; background: var(--text);
  transform: scaleY(.3); animation: wave 1.05s ease-in-out infinite;
}
.bars i:nth-child(2) { animation-delay: -.85s; }
.bars i:nth-child(3) { animation-delay: -.65s; }
.bars i:nth-child(4) { animation-delay: -.45s; }
.bars i:nth-child(5) { animation-delay: -.25s; }
@keyframes wave { 0%,100% { transform: scaleY(.28); opacity: .55; } 50% { transform: scaleY(1); opacity: 1; } }

/* shimmering label while working */
.shimmer {
  background: linear-gradient(90deg, var(--muted) 0%, var(--text) 45%, var(--muted) 90%);
  background-size: 220% 100%;
  -webkit-background-clip: text; background-clip: text; color: transparent;
  animation: shimmer 1.6s linear infinite;
}
@keyframes shimmer { from { background-position: 120% 0; } to { background-position: -120% 0; } }

.icon { width: 18px; height: 18px; border-radius: 50%; display: grid; place-items: center; flex: none;
        animation: pop .35s var(--spring); }
.icon.ok  { background: var(--ok); }
.icon.err { background: var(--err); }
.icon.info { background: rgba(255,255,255,0.16); }
.icon svg { width: 11px; height: 11px; }
.icon svg path { fill: none; stroke: #fff; stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round;
                 stroke-dasharray: 20; stroke-dashoffset: 20; animation: draw .32s .12s ease-out forwards; }
@keyframes draw { to { stroke-dashoffset: 0; } }
@keyframes pop  { from { transform: scale(.4); opacity: 0; } to { transform: none; opacity: 1; } }
.detail { color: var(--muted); font-variant-numeric: tabular-nums; }
.label { max-width: 420px; overflow: hidden; text-overflow: ellipsis; }
</style></head>
<body>
<div id="pill"><div id="content"></div></div>
<script>
const pill = document.getElementById('pill');
const content = document.getElementById('content');
const ICONS = {
  ok:   '<path d="M3 8.5l3.2 3L13 4.8"/>',
  err:  '<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>',
  info: '<path d="M8 4.5v4.5M8 11.8v0"/>'
};
function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }
function icon(kind) {
  return '<span class="icon ' + kind + '"><svg viewBox="0 0 16 16">' + ICONS[kind] + '</svg></span>';
}
function fit() {
  pill.style.width = Math.ceil(content.scrollWidth) + 'px';
}
function setState(kind, label, detail) {
  if (kind === 'hidden' || kind === 'idle') {
    pill.className = kind === 'idle' ? 'idle' : '';
    pill.style.width = '';
    return;
  }
  let html = '';
  if (kind === 'working') {
    html = '<span class="bars"><i></i><i></i><i></i><i></i><i></i></span>'
         + '<span class="label shimmer">' + esc(label) + '</span>';
  } else {
    html = icon(kind) + '<span class="label">' + esc(label) + '</span>';
    if (detail) html += '<span class="detail">' + esc(detail) + '</span>';
  }
  content.innerHTML = html;
  pill.className = 'active';
  fit();
}
</script>
</body></html>]]

local function settle()
    -- Collapse back to the resting pill (or disappear entirely).
    cancel_timer()
    if idle_enabled() then
        _state = "idle"
        js("setState('idle')")
        _timer = hs.timer.doAfter(COLLAPSE_S, function()
            _timer = nil
            if _state == "idle" and _wv then
                set_size(IDLE_SIZE)
                _wv:show()
            end
        end)
    else
        _state = "hidden"
        js("setState('hidden')")
        _timer = hs.timer.doAfter(COLLAPSE_S, function()
            _timer = nil
            if _state == "hidden" and _wv then _wv:hide() end
        end)
    end
end

local function show_active(kind, label, detail, hold)
    if not _wv then M.init() end
    if not _wv then return end
    cancel_timer()
    _state = kind
    set_size(ACTIVE_SIZE)
    _wv:show()
    js(string.format("setState(%q, %s, %s)", kind,
        hs.json.encode({ label or "" }):sub(2, -2),
        hs.json.encode({ detail or "" }):sub(2, -2)))
    if hold then
        _timer = hs.timer.doAfter(hold, function()
            _timer = nil
            settle()
        end)
    end
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.init()
    if _wv then return end
    _ready = false
    _wv = hs.webview.new(frame_for(IDLE_SIZE), { developerExtrasEnabled = false })
    if not _wv then return end
    _size = IDLE_SIZE
    _wv:windowStyle({ "borderless", "nonactivating" })
    _wv:transparent(true)
    _wv:shadow(false)
    _wv:allowTextEntry(false)
    _wv:level(hs.drawing.windowLevels.overlay)
    _wv:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary", "ignoresCycle" })
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
    if idle_enabled() then
        _state = "idle"
        _pending = "setState('idle')"
        _wv:show()
    end
end

function M.working(label)
    show_active("working", label or "Working", nil, nil)
end

function M.success(label, detail)
    show_active("ok", label or "Done", detail, HOLD.success)
end

function M.error(msg)
    show_active("err", msg or "Something went wrong", nil, HOLD.error)
end

function M.info(msg, detail)
    show_active("info", msg, detail, HOLD.info)
end

function M.configure(settings)
    _idle = (settings and settings.enabled) == true
    if _wv and (_state == "idle" or _state == "hidden") then settle() end
end

function M.idle_visible()
    return idle_enabled()
end

function M.destroy()
    cancel_timer()
    if _wv then _wv:delete(); _wv = nil end
    _ready, _pending, _state = false, nil, "hidden"
end

return M
