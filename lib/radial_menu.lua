-- radial_menu.lua — hold-and-flick mode ring at the cursor (IDEAS 3.1)
-- Hold the trigger (Right ⌥ by default) and the modes spring out in a ring
-- around the pointer. Move toward one (the direction highlights live) and
-- release the trigger to apply it. Releasing near the center cancels. While the
-- ring is open: 1–8 apply directly, click applies the highlighted mode, esc cancels,
-- and any other key cancels and passes through (so ⌥-characters still type).
-- Slots are fixed: the first mode is always at the top, the rest go clockwise,
-- so directions become muscle memory.
-- Public API:
--   M.configure(settings, config)   features.radial_menu table + full config
--   M.teardown()

local M = {}

local W, H       = 540, 340   -- window; the ring is drawn around (cx, cy) inside it
local RADIUS     = 118
local SQUASH     = 0.78       -- vertical radius factor (a slightly flattened ring reads better)
local DEADZONE   = 28         -- px from the press point before a direction is picked
local MAX_SLOTS  = 8

-- Right-hand modifiers: keycode and device-dependent flag bit (NX_DEVICER*KEYMASK).
local MODIFIER_KEYS = {
    right_option  = { code = 61, mask = 0x40,   flag = "alt"   },
    right_command = { code = 54, mask = 0x10,   flag = "cmd"   },
    right_control = { code = 62, mask = 0x2000, flag = "ctrl"  },
    right_shift   = { code = 60, mask = 0x04,   flag = "shift" },
}

local _settings = nil
local _config   = nil
local _slots    = {}     -- modes in ring order
local _wv       = nil
local _ready    = false
local _flag_tap = nil    -- persistent: watches the trigger modifier
local _hotkey   = nil    -- chord trigger
local _tap      = nil    -- per-session: keys, mouse
local _timer    = nil
local _session  = nil    -- { state = "pending" | "open", origin, sel }

-- ── HTML ──────────────────────────────────────────────────────────────────────

local HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>
:root {
  --surface: rgba(20,20,22,0.96);
  --hairline: rgba(255,255,255,0.12);
  --text: #f5f5f7;
  --muted: rgba(245,245,247,0.55);
  --accent: #0a84ff;
  --spring: cubic-bezier(.32,1.35,.5,1);
}
html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
body {
  position: relative;
  font: 500 13px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  letter-spacing: -0.01em; color: var(--text); -webkit-font-smoothing: antialiased;
  cursor: default; user-select: none;
}
#halo {
  position: absolute; width: 400px; height: 330px; transform: translate(-50%,-50%) scale(.6);
  background: radial-gradient(closest-side, rgba(0,0,0,0.32), rgba(0,0,0,0.16) 60%, transparent);
  opacity: 0; transition: opacity .2s ease, transform .35s var(--spring);
}
#hub {
  position: absolute; width: 46px; height: 46px; border-radius: 50%;
  transform: translate(-50%,-50%) scale(.4); opacity: 0;
  background: var(--surface); box-shadow: inset 0 0 0 1px var(--hairline), 0 6px 20px rgba(0,0,0,0.4);
  transition: opacity .15s ease, transform .3s var(--spring);
  display: grid; place-items: center;
}
#hub .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--muted); transition: background .15s; }
#arrow { position: absolute; inset: 0; opacity: 0; transition: opacity .12s ease; }
#arrow::after {
  content: ''; position: absolute; left: 50%; top: -1px; margin-left: -6px;
  border: 6px solid transparent; border-bottom: 8px solid var(--accent); border-top: 0;
}
#caption {
  position: absolute; transform: translate(-50%, 0); margin-top: 31px; white-space: nowrap;
  font-size: 11px; color: var(--muted); opacity: 0; transition: opacity .2s ease .12s;
  padding: 4px 9px; border-radius: 999px; background: var(--surface);
  box-shadow: inset 0 0 0 1px var(--hairline);
}
.item {
  position: absolute; display: flex; align-items: center; gap: 8px;
  height: 32px; padding: 0 13px 0 7px; border-radius: 999px; white-space: nowrap; max-width: 170px;
  background: var(--surface); box-shadow: inset 0 0 0 1px var(--hairline), 0 8px 24px rgba(0,0,0,0.38);
  transform: translate(var(--tx),-50%) scale(.3); opacity: 0;
  transition: transform .42s var(--spring) calc(var(--i) * 30ms),
              opacity .2s ease calc(var(--i) * 30ms),
              background .12s ease;
}
.item .num {
  width: 18px; height: 18px; border-radius: 50%; flex: none; display: grid; place-items: center;
  font-size: 10.5px; font-weight: 600; color: var(--muted); background: rgba(255,255,255,0.08);
}
.item .name { overflow: hidden; text-overflow: ellipsis; }
.open #halo    { opacity: 1; transform: translate(-50%,-50%) scale(1); }
.open #hub     { opacity: 1; transform: translate(-50%,-50%) scale(1); }
.open #caption { opacity: 1; }
.open .item    { opacity: 1; transform: translate(var(--tx),-50%) translate(var(--dx), var(--dy)) scale(1); }
.open .item.sel {
  background: var(--accent); transition-delay: 0s;
  transform: translate(var(--tx),-50%) translate(var(--dx), var(--dy)) scale(1.1);
  box-shadow: 0 10px 28px rgba(10,132,255,0.45);
}
.item.sel .num { background: rgba(255,255,255,0.25); color: #fff; }
.sel-on #arrow { opacity: 1; }
.sel-on #hub .dot { background: var(--accent); }
.closing .item, .closing #hub, .closing #halo, .closing #caption { transition-duration: .14s; transition-delay: 0s; }
.closing .item.sel { opacity: 1; transform: translate(var(--tx),-50%) translate(var(--dx), var(--dy)) scale(1.18); }
</style></head>
<body>
<div id="halo"></div>
<div id="stage"></div>
<div id="hub"><div id="arrow"></div><span class="dot"></span></div>
<div id="caption"></div>
<script>
const body = document.body, stage = document.getElementById('stage');
let items = [];
function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; }
function place(el, x, y) { el.style.left = x + 'px'; el.style.top = y + 'px'; }
function render(d) {
  body.className = '';
  ['halo','hub','caption'].forEach(function(id) { place(document.getElementById(id), d.cx, d.cy); });
  document.getElementById('caption').textContent = d.caption;
  stage.innerHTML = d.items.map(function(it, i) {
    return '<div class="item" style="--i:' + i + ';--dx:' + it.dx + 'px;--dy:' + it.dy + 'px;--tx:' + it.tx + '%;left:' + d.cx + 'px;top:' + d.cy + 'px">'
      + '<span class="num">' + (i + 1) + '</span><span class="name">' + esc(it.name) + '</span></div>';
  }).join('');
  items = Array.prototype.slice.call(stage.children);
}
function enter() { requestAnimationFrame(function() { body.classList.add('open'); }); }
function select(i, deg) {
  items.forEach(function(el, k) { el.classList.toggle('sel', k === i); });
  body.classList.toggle('sel-on', i >= 0);
  if (i >= 0) document.getElementById('arrow').style.transform = 'rotate(' + (deg + 90) + 'deg)';
}
function leave() { body.classList.add('closing'); body.classList.remove('open'); }
</script>
</body></html>]]

-- ── geometry ──────────────────────────────────────────────────────────────────

-- Slot k (1-based) sits at angle -90° + (k-1)·step, i.e. first at the top, clockwise.
-- Returns the offset from the center plus the pill's horizontal anchor (as a
-- CSS translate %): pills on the right grow rightward and pills on the left
-- grow leftward, so neighbors never overlap however long the names are.
local function slot_offset(k, n)
    local a = math.rad(-90 + (k - 1) * 360 / n)
    local c = math.cos(a)
    local dx = math.floor(RADIUS * 0.55 * c + 0.5)
    local dy = math.floor(RADIUS * SQUASH * math.sin(a) + 0.5)
    local side = math.max(-1, math.min(1, c * 2))   -- clearly left/right → fully edge-anchored
    local tx = -math.floor(50 - 50 * side + 0.5)
    return dx, dy, tx
end

-- Nearest slot to the pointer direction, or nil inside the dead zone.
local function slot_for(dx, dy, n)
    if n == 0 or (dx * dx + dy * dy) < DEADZONE * DEADZONE then return nil end
    local deg = math.deg(math.atan(dy, dx))              -- screen coords: +y is down
    local from_top = (deg + 90) % 360
    local step = 360 / n
    return (math.floor(from_top / step + 0.5) % n) + 1, deg
end

local function caret_point()
    local ok, pt = pcall(function()
        local el = hs.axuielement.systemElement():attributeValue("AXFocusedUIElement")
        if not el then return nil end
        local range = el:attributeValue("AXSelectedTextRange")
        if not range then return nil end
        local r = el:parameterizedAttributeValue("AXBoundsForRange", range)
        if not r or not r.x or (r.w == 0 and r.h == 0) then return nil end
        return { x = r.x + r.w / 2, y = r.y + r.h / 2 }
    end)
    return ok and pt or nil
end

-- ── session ───────────────────────────────────────────────────────────────────

local function stop_timer() if _timer then _timer:stop(); _timer = nil end end
local function stop_tap()   if _tap   then _tap:stop();   _tap   = nil end end

local function hide()
    if _wv and _ready then
        _wv:evaluateJavaScript("leave()")
        _wv:hide(0.16)
    end
end

local function cancel()
    stop_timer()
    stop_tap()
    if _session and _session.state == "open" then hide() end
    _session = nil
end

local function apply(k)
    local mode = k and _slots[k]
    local cfg  = _config
    if _wv and _ready and k then _wv:evaluateJavaScript(string.format("select(%d, 0)", k - 1)) end
    cancel()
    if not mode then return end
    require("flickwise.lib.notifier").log("Radial menu → " .. mode.name)
    -- Let the ring fade and the trigger's key-up settle before ⌘C is sent.
    hs.timer.doAfter(0.06, function()
        require("flickwise.lib.text_replacer").run(mode, cfg)
    end)
end

local function update_selection()
    local s = _session
    if not (s and s.state == "open") then return end
    local p = hs.mouse.absolutePosition()
    local k, deg = slot_for(p.x - s.origin.x, p.y - s.origin.y, #_slots)
    if k ~= s.sel then
        s.sel = k
        _wv:evaluateJavaScript(string.format("select(%d, %.1f)", k and (k - 1) or -1, deg or 0))
    elseif k then
        _wv:evaluateJavaScript(string.format("select(%d, %.1f)", k - 1, deg))
    end
end

local function open_ring()
    local s = _session
    if not s or s.state ~= "pending" or not _ready or #_slots == 0 then cancel(); return end
    s.state = "open"
    require("flickwise.lib.diff_bubble").dismiss()

    local anchor = (_settings.anchor == "caret" and caret_point()) or s.origin
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local sf = screen:frame()
    local fx = math.max(sf.x, math.min(anchor.x - W / 2, sf.x + sf.w - W))
    local fy = math.max(sf.y, math.min(anchor.y - H / 2, sf.y + sf.h - H))

    local items = {}
    for k, mode in ipairs(_slots) do
        local dx, dy, tx = slot_offset(k, #_slots)
        table.insert(items, { name = mode.name, dx = dx, dy = dy, tx = tx })
    end
    _wv:frame({ x = fx, y = fy, w = W, h = H })
    _wv:evaluateJavaScript("render(" .. hs.json.encode({
        cx = math.floor(anchor.x - fx), cy = math.floor(anchor.y - fy),
        items = items, caption = "Flick toward a mode · release",
    }) .. ")")
    _wv:show()
    _wv:evaluateJavaScript("enter()")
    update_selection()
end

local function digit_of(code)
    for d = 1, 9 do if code == hs.keycodes.map[tostring(d)] then return d end end
    return nil
end

local function on_session_event(e)
    local s = _session
    if not s then return false end
    local t, types = e:getType(), hs.eventtap.event.types

    if t == types.keyDown then
        local code = e:getKeyCode()
        if s.trigger_code and code == s.trigger_code then return true end   -- chord auto-repeat
        if s.state == "pending" then cancel(); return false end            -- user is typing an ⌥-char
        if code == hs.keycodes.map.escape then cancel(); return true end
        local d = digit_of(code)
        if d and d <= #_slots then apply(d); return true end
        cancel()
        return false
    end

    if s.state ~= "open" then return false end
    if t == types.mouseMoved or t == types.leftMouseDragged then
        update_selection()
        return false
    end
    if t == types.leftMouseDown then
        update_selection()
        apply(s.sel)
        return true
    end
    if t == types.rightMouseDown then cancel(); return true end
    return false
end

local function start_session(trigger_code)
    cancel()
    if #_slots == 0 or require("flickwise.lib.text_replacer").is_in_flight() then return end
    _session = { state = "pending", origin = hs.mouse.absolutePosition(), trigger_code = trigger_code }
    local types = hs.eventtap.event.types
    _tap = hs.eventtap.new(
        { types.keyDown, types.mouseMoved, types.leftMouseDragged, types.leftMouseDown, types.rightMouseDown },
        function(e)
            local ok, res = xpcall(on_session_event, debug.traceback, e)
            if not ok then
                require("flickwise.lib.notifier").log("Radial menu error: " .. tostring(res))
                cancel()
                return false
            end
            return res
        end)
    _tap:start()
end

local function end_session()
    local s = _session
    if not s then return end
    if s.state == "open" then
        update_selection()
        apply(s.sel)            -- nil (released in the center) just closes
    else
        cancel()                -- a quick tap, not a hold
    end
end

-- ── triggers ──────────────────────────────────────────────────────────────────

local function bind_modifier_trigger(name)
    local key = MODIFIER_KEYS[name]
    local others = { "cmd", "alt", "ctrl", "shift", "fn" }
    _flag_tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
        local ok, err = pcall(function()
            local code = e:getKeyCode()
            if code ~= key.code then
                -- Another modifier joined in while waiting: it's a chord, not ours.
                if _session and _session.state == "pending" then cancel() end
                return
            end
            local down = (e:rawFlags() & key.mask) ~= 0
            if down then
                local flags = e:getFlags()
                for _, m in ipairs(others) do
                    if m ~= key.flag and flags[m] then return end
                end
                start_session(nil)
                _timer = hs.timer.doAfter(_settings.hold_ms / 1000, function()
                    _timer = nil
                    open_ring()
                end)
            else
                end_session()
            end
        end)
        if not ok then require("flickwise.lib.notifier").log("Radial trigger error: " .. tostring(err)) end
        return false   -- never swallow modifier events
    end)
    _flag_tap:start()
end

local function bind_chord_trigger(chord)
    local mods, key = {}, nil
    for _, part in ipairs(chord) do
        local p = tostring(part):lower()
        if     p == "cmd" or p == "command"               then table.insert(mods, "cmd")
        elseif p == "shift"                               then table.insert(mods, "shift")
        elseif p == "ctrl" or p == "control"              then table.insert(mods, "ctrl")
        elseif p == "alt" or p == "opt" or p == "option"  then table.insert(mods, "alt")
        else   key = p end
    end
    if not key then return false end
    local ok, hk = pcall(hs.hotkey.bind, mods, key,
        function()
            start_session(hs.keycodes.map[key])
            if _session then _session.state = "pending"; open_ring() end
        end,
        function() end_session() end)
    if ok and hk then _hotkey = hk; return true end
    require("flickwise.lib.notifier").log("WARNING: radial menu chord bind failed: " .. tostring(hk))
    return false
end

local function build_webview()
    _ready = false
    _wv = hs.webview.new({ x = 0, y = 0, w = W, h = H }, { developerExtrasEnabled = false })
    _wv:windowStyle({ "borderless", "nonactivating" })
    _wv:transparent(true)
    _wv:shadow(false)
    _wv:allowTextEntry(false)
    _wv:level(hs.drawing.windowLevels.popUpMenu)
    _wv:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary", "ignoresCycle" })
    _wv:navigationCallback(function(action)
        if action == "didFinishNavigation" then _ready = true end
    end)
    _wv:html(HTML)
end

local function pick_slots(config, names)
    local out = {}
    if type(names) == "table" and #names > 0 then
        local by_name = {}
        for _, mode in ipairs(config.modes) do by_name[mode.name:lower()] = mode end
        for _, n in ipairs(names) do
            local mode = by_name[tostring(n):lower()]
            if mode then table.insert(out, mode)
            else require("flickwise.lib.notifier").log("WARNING: radial_menu.modes: no mode named '" .. tostring(n) .. "'") end
            if #out == MAX_SLOTS then break end
        end
    else
        for i = 1, math.min(#config.modes, MAX_SLOTS) do table.insert(out, config.modes[i]) end
    end
    return out
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.teardown()
    cancel()
    if _flag_tap then _flag_tap:stop(); _flag_tap = nil end
    if _hotkey then pcall(function() _hotkey:delete() end); _hotkey = nil end
    if _wv then _wv:delete(); _wv = nil end
    _ready = false
end

function M.configure(settings, config)
    M.teardown()
    _settings, _config = settings, config
    if not (settings and settings.enabled and config and config.modes) then return end
    _slots = pick_slots(config, settings.modes)
    if #_slots == 0 then return end

    build_webview()   -- preload so the first hold opens instantly
    local trigger = settings.trigger
    if type(trigger) == "table" then
        bind_chord_trigger(trigger)
    else
        bind_modifier_trigger(trigger)
    end
    require("flickwise.lib.notifier").log("Radial menu ready (" .. #_slots .. " modes, trigger "
        .. (type(trigger) == "table" and table.concat(trigger, "+") or trigger) .. ")")
end

return M
