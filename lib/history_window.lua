-- history_window.lua — "History…" window: past fixes + My Progress (IDEAS 2.4)
-- History tab: searchable list (newest first). Selecting an entry shows its word
-- diff (or, for "show" modes, the text and the answer) with Copy/Delete.
-- Progress tab: this week vs last week, mistake categories, most repeated
-- corrections, and an 8-week trend, all from history.stats().
-- Public API: M.open(), M.close()

local M = {}

local history   = require("flickwise.lib.history")
local word_diff = require("flickwise.lib.word_diff")

local _wv = nil

local HTML = [[<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>
:root {
  --bg: #1c1c1e; --panel: #141416; --hairline: rgba(255,255,255,0.09);
  --text: #f5f5f7; --muted: rgba(245,245,247,0.55); --faint: rgba(245,245,247,0.32);
  --accent: #0a84ff; --sel: rgba(10,132,255,0.22);
  --ok: #30d158; --ok-bg: rgba(48,209,88,0.16); --err: #ff6961; --err-bg: rgba(255,69,58,0.14);
}
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; -webkit-font-smoothing: antialiased; }
body { display: flex; flex-direction: column; }
header { display: flex; align-items: center; gap: 14px; padding: 12px 16px; border-bottom: 1px solid var(--hairline); }
.tabs { display: flex; background: rgba(255,255,255,0.06); border-radius: 8px; padding: 2px; }
.tab { padding: 5px 14px; border-radius: 6px; color: var(--muted); cursor: default; font-weight: 500; }
.tab.on { background: rgba(255,255,255,0.14); color: var(--text); }
#search { flex: 1; max-width: 320px; margin-left: auto; background: rgba(255,255,255,0.07); border: 1px solid var(--hairline);
  border-radius: 7px; color: var(--text); padding: 6px 10px; font: inherit; outline: none; }
#search:focus { border-color: var(--accent); }
main { flex: 1; min-height: 0; display: flex; }
.pane { display: none; flex: 1; min-height: 0; }
.pane.on { display: flex; }
/* history */
#list { width: 330px; overflow-y: auto; border-right: 1px solid var(--hairline); }
.item { padding: 10px 14px; border-bottom: 1px solid var(--hairline); cursor: default; }
.item:hover { background: rgba(255,255,255,0.04); }
.item.on { background: var(--sel); }
.meta { display: flex; gap: 6px; align-items: center; font-size: 11px; color: var(--muted); margin-bottom: 3px; }
.badge { font-size: 10px; padding: 1px 6px; border-radius: 999px; background: rgba(255,255,255,0.08); color: var(--muted); }
.badge.m { background: var(--err-bg); color: var(--err); }
.badge.u { background: rgba(255,255,255,0.08); color: var(--faint); }
.snip { color: rgba(245,245,247,0.85); overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
#detail { flex: 1; overflow-y: auto; padding: 18px 22px; }
.empty { color: var(--faint); padding: 40px 20px; text-align: center; }
.dh { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 12px; margin-bottom: 14px; }
.dh b { color: var(--text); font-size: 14px; }
.block { background: var(--panel); border: 1px solid var(--hairline); border-radius: 10px; padding: 12px 14px; margin-bottom: 12px;
  white-space: pre-wrap; word-wrap: break-word; line-height: 1.55; font-size: 13.5px; user-select: text; }
.lbl { display: block; font-size: 10.5px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); margin-bottom: 5px; }
del { color: var(--err); background: var(--err-bg); text-decoration: line-through; border-radius: 4px; padding: 0 2px; }
ins { color: var(--ok); background: var(--ok-bg); text-decoration: none; border-radius: 4px; padding: 0 2px; font-weight: 500; }
.actions { display: flex; gap: 8px; margin-top: 4px; }
button { font: inherit; font-weight: 500; color: var(--text); background: rgba(255,255,255,0.08); border: 1px solid var(--hairline);
  border-radius: 7px; padding: 6px 12px; }
button:hover { background: rgba(255,255,255,0.14); }
button.danger { color: var(--err); }
button.done { color: var(--ok); }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 12px; }
.chip { font-size: 12px; padding: 3px 9px; border-radius: 999px; background: rgba(255,255,255,0.06); }
.chip i { font-style: normal; color: var(--muted); margin-left: 4px; }
/* progress */
#progress { overflow-y: auto; padding: 18px 22px; flex-direction: column; gap: 16px; }
.cards { display: flex; gap: 12px; }
.card { flex: 1; background: var(--panel); border: 1px solid var(--hairline); border-radius: 10px; padding: 12px 14px; }
.card .n { font-size: 26px; font-weight: 600; letter-spacing: -0.02em; }
.card .t { color: var(--muted); font-size: 12px; }
.card .d { font-size: 12px; margin-top: 2px; }
.good { color: var(--ok); } .bad { color: var(--err); }
h3 { margin: 4px 0 8px; font-size: 13px; color: var(--muted); font-weight: 600; }
.bar { display: flex; align-items: center; gap: 10px; margin: 6px 0; }
.bar .name { width: 210px; flex: none; }
.bar .track { flex: 1; height: 8px; background: rgba(255,255,255,0.06); border-radius: 999px; overflow: hidden; }
.bar .fill { height: 100%; background: var(--accent); border-radius: 999px; }
.bar .v { width: 70px; text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; font-size: 12px; }
table { width: 100%; border-collapse: collapse; }
td { padding: 6px 4px; border-bottom: 1px solid var(--hairline); }
td.c { text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; }
.trend { display: flex; align-items: flex-end; gap: 8px; height: 110px; padding-top: 6px; }
.col { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 4px; height: 100%; justify-content: flex-end; }
.col .b { width: 100%; max-width: 38px; background: var(--accent); border-radius: 4px 4px 0 0; min-height: 2px; }
.col .x { font-size: 10px; color: var(--faint); white-space: nowrap; }
.col .y { font-size: 10px; color: var(--muted); }
footer { display: flex; align-items: center; gap: 10px; padding: 9px 16px; border-top: 1px solid var(--hairline); color: var(--faint); font-size: 11.5px; }
footer button { margin-left: auto; padding: 4px 10px; font-size: 12px; }
</style></head>
<body>
<header>
  <div class="tabs"><span class="tab on" data-t="history">History</span><span class="tab" data-t="progress">My Progress</span></div>
  <input id="search" placeholder="Search text, mode, or app…">
</header>
<main>
  <div class="pane on" id="history"><div id="list"></div><div id="detail"><div class="empty">Select an entry</div></div></div>
  <div class="pane" id="progress"></div>
</main>
<footer><span id="note"></span><button class="danger" id="clear">Clear all history</button></footer>
<script>
const post = (m) => window.webkit.messageHandlers.history.postMessage(m);
let data = { entries: [], stats: null, enabled: true }, current = null, armed = false;
function esc(s) { const d = document.createElement('div'); d.textContent = s == null ? '' : s; return d.innerHTML; }
function when(ts) {
  const d = new Date(ts * 1000), now = new Date();
  const t = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (d.toDateString() === now.toDateString()) return 'Today ' + t;
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return 'Yesterday ' + t;
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + t;
}
// Empty Lua tables may arrive as {} instead of []; normalize every list.
const arr = (x) => Array.isArray(x) ? x : [];
function load(d) {
  d.entries = arr(d.entries);
  ['categories', 'top', 'weeks', 'tracked_modes'].forEach(k => { d.stats[k] = arr(d.stats[k]); });
  data = d;
  document.getElementById('note').textContent = d.enabled
    ? 'Stored only on this Mac · kept ' + d.stats.retention_days + ' days · ' + d.entries.length + ' entries'
    : 'History is turned off (menu bar → Features). Existing entries are shown below.';
  renderList(); renderProgress();
  if (current && !d.entries.some(e => e.id === current)) { current = null; document.getElementById('detail').innerHTML = '<div class="empty">Select an entry</div>'; }
}
function renderList() {
  const q = document.getElementById('search').value.trim().toLowerCase();
  const items = data.entries.filter(e => !q || [e.original, e.result, e.mode, e.app].join(' ').toLowerCase().indexOf(q) >= 0);
  const list = document.getElementById('list');
  if (!items.length) { list.innerHTML = '<div class="empty">' + (data.entries.length ? 'No matches' : 'No fixes yet. They\'ll appear here.') + '</div>'; return; }
  list.innerHTML = items.map(e => '<div class="item' + (e.id === current ? ' on' : '') + '" data-id="' + e.id + '">'
    + '<div class="meta"><span>' + esc(when(e.ts)) + '</span><span>·</span><span>' + esc(e.mode) + '</span>'
    + (e.app ? '<span>· ' + esc(e.app) + '</span>' : '')
    + (e.undone ? '<span class="badge u">undone</span>' : (e.n_mistakes ? '<span class="badge m">' + e.n_mistakes + ' mistake' + (e.n_mistakes > 1 ? 's' : '') + '</span>' : ''))
    + '</div><div class="snip">' + esc(e.output === 'show' ? e.original : e.result) + '</div></div>').join('');
}
function rows(text) {
  return String(text || '').split('\n').map(function(line) {
    const m = line.match(/^\s*\**([A-Za-z][A-Za-z ]{0,24}?)\**\s*:\s*(.*)$/);
    return m ? '<span class="lbl">' + esc(m[1]) + '</span>' + esc(m[2]) : esc(line);
  }).join('\n');
}
function showDetail(d) {
  d.segs = arr(d.segs); d.mistakes = arr(d.mistakes);
  current = d.id; renderList();
  const segs = (d.segs || []).map(s => s.op === 'del' ? '<del>' + esc(s.text) + '</del>' : s.op === 'ins' ? '<ins>' + esc(s.text) + '</ins>' : esc(s.text)).join('');
  let html = '<div class="dh"><b>' + esc(d.mode) + '</b><span>· ' + esc(when(d.ts)) + '</span>' + (d.app ? '<span>· ' + esc(d.app) + '</span>' : '')
    + (d.undone ? '<span class="badge u">undone</span>' : '') + '</div>';
  if (d.output === 'show') {
    html += '<div class="block"><span class="lbl">Selected text</span>' + esc(d.original) + '</div>'
          + '<div class="block">' + rows(d.result) + '</div>';
  } else {
    html += '<div class="block"><span class="lbl">What changed</span>' + segs + '</div>';
    if (d.mistakes && d.mistakes.length) {
      html += '<div class="chips">' + d.mistakes.map(m => '<span class="chip">' + esc(m.from || '∅') + ' → ' + esc(m.to || '∅') + '<i>' + esc(m.cat) + '</i></span>').join('') + '</div>';
    }
  }
  html += '<div class="actions"><button data-copy="original">Copy original</button><button data-copy="result">Copy '
    + (d.output === 'show' ? 'answer' : 'fixed') + '</button><button class="danger" id="del">Delete</button></div>';
  document.getElementById('detail').innerHTML = html;
}
function delta(now, prev, lowerIsBetter) {
  if (!prev) return '';
  const diff = now - prev; if (!diff) return '<div class="d">same as last week</div>';
  const good = lowerIsBetter ? diff < 0 : diff > 0;
  return '<div class="d ' + (good ? 'good' : 'bad') + '">' + (diff > 0 ? '▲ ' : '▼ ') + Math.abs(Math.round(diff * 10) / 10) + ' vs last week</div>';
}
function renderProgress() {
  const s = data.stats, el = document.getElementById('progress');
  if (!s) return;
  const rate = (b) => b.fixes ? b.mistakes / b.fixes : 0;
  const tw = s.this_week, lw = s.last_week;
  let html = '<div class="cards">'
    + '<div class="card"><div class="n">' + tw.fixes + '</div><div class="t">fixes this week</div>' + delta(tw.fixes, lw.fixes, false) + '</div>'
    + '<div class="card"><div class="n">' + tw.mistakes + '</div><div class="t">mistakes corrected</div>' + delta(tw.mistakes, lw.mistakes, true) + '</div>'
    + '<div class="card"><div class="n">' + (Math.round(rate(tw) * 10) / 10) + '</div><div class="t">mistakes per fix</div>' + delta(rate(tw), rate(lw), true) + '</div>'
    + '</div>';
  if (!s.categories.length) {
    html += '<div class="empty">No mistakes tracked yet. Use ' + esc((s.tracked_modes || []).join(', ') || 'a tracked mode') + ' and your progress will show up here.</div>';
  } else {
    const max = Math.max.apply(null, s.categories.map(c => c.total));
    html += '<div><h3>Mistake types</h3>' + s.categories.map(c => '<div class="bar"><span class="name">' + esc(c.name) + '</span>'
      + '<span class="track"><span class="fill" style="display:block;width:' + Math.round(c.total / max * 100) + '%"></span></span>'
      + '<span class="v">' + c.week + ' wk · ' + c.total + '</span></div>').join('') + '</div>';
    if (s.top.length) {
      html += '<div><h3>Most repeated corrections</h3><table>' + s.top.map(p => '<tr><td><del>' + esc(p.from || '∅') + '</del> → <ins>' + esc(p.to || '∅') + '</ins></td>'
        + '<td style="color:var(--muted)">' + esc(p.cat) + '</td><td class="c">×' + p.count + '</td></tr>').join('') + '</table></div>';
    }
    const wmax = Math.max(1, Math.max.apply(null, s.weeks.map(w => w.mistakes)));
    html += '<div><h3>Mistakes per week</h3><div class="trend">' + s.weeks.map(w => '<div class="col"><span class="y">' + w.mistakes + '</span>'
      + '<span class="b" style="height:' + Math.round(w.mistakes / wmax * 80) + 'px"></span><span class="x">' + esc(w.label) + '</span></div>').join('') + '</div></div>';
  }
  html += '<div style="color:var(--faint);font-size:11.5px">Tracked modes: ' + esc((s.tracked_modes || []).join(', ') || 'none')
    + ' (<code>features.history.mistake_modes</code>). Undone fixes don\'t count.</div>';
  el.innerHTML = html;
}
document.querySelector('.tabs').addEventListener('click', function(e) {
  const t = e.target.closest('.tab'); if (!t) return;
  document.querySelectorAll('.tab').forEach(x => x.classList.toggle('on', x === t));
  document.querySelectorAll('.pane').forEach(p => p.classList.toggle('on', p.id === t.dataset.t));
  document.getElementById('search').style.visibility = t.dataset.t === 'history' ? 'visible' : 'hidden';
});
document.getElementById('search').addEventListener('input', renderList);
document.getElementById('list').addEventListener('click', function(e) {
  const it = e.target.closest('.item'); if (it) post({ action: 'detail', id: it.dataset.id });
});
document.getElementById('detail').addEventListener('click', function(e) {
  const b = e.target.closest('button'); if (!b || !current) return;
  if (b.dataset.copy) { post({ action: 'copy', id: current, which: b.dataset.copy }); b.textContent = 'Copied ✓'; b.classList.add('done'); }
  else if (b.id === 'del') post({ action: 'delete', id: current });
});
document.getElementById('clear').addEventListener('click', function(e) {
  if (!armed) { armed = true; e.target.textContent = 'Click again to delete everything';
    setTimeout(function() { armed = false; e.target.textContent = 'Clear all history'; }, 3000); return; }
  armed = false; e.target.textContent = 'Clear all history'; post({ action: 'clear' });
});
document.addEventListener('keydown', function(e) { if (e.key === 'Escape') post({ action: 'close' }); });
</script>
</body></html>]]

local function payload()
    local entries = {}
    for _, e in ipairs(history.entries()) do
        table.insert(entries, {
            id = e.id, ts = e.ts, mode = e.mode, app = e.app, output = e.output,
            original = e.original, result = e.result, undone = e.undone,
            n_mistakes = e.mistakes and #e.mistakes or 0,
        })
    end
    return { entries = entries, stats = history.stats(), enabled = history.enabled() }
end

local function refresh()
    if _wv then _wv:evaluateJavaScript("load(" .. hs.json.encode(payload()) .. ")") end
end

local function on_message(msg)
    local d = msg.body
    if type(d) ~= "table" then return end
    if d.action == "ready" then
        refresh()
    elseif d.action == "detail" then
        local e = history.get(d.id)
        if not e then return end
        local out = { id = e.id, ts = e.ts, mode = e.mode, app = e.app, output = e.output,
                      original = e.original, result = e.result, undone = e.undone, mistakes = e.mistakes }
        if e.output ~= "show" then out.segs = (word_diff.diff(e.original, e.result)) end
        _wv:evaluateJavaScript("showDetail(" .. hs.json.encode(out) .. ")")
    elseif d.action == "copy" then
        local e = history.get(d.id)
        if e then hs.pasteboard.setContents(d.which == "original" and e.original or e.result) end
    elseif d.action == "delete" then
        history.delete(d.id)
        refresh()
    elseif d.action == "clear" then
        history.clear()
        refresh()
    elseif d.action == "close" then
        M.close()
    end
end

-- A menu bar app's window doesn't come forward on its own: focus it explicitly.
local function focus()
    _wv:show()
    _wv:bringToFront(true)
    local w = _wv:hswindow()
    if w then w:focus() end
end

function M.open()
    if _wv then
        focus()
        refresh()
        return
    end
    local uc = hs.webview.usercontent.new("history")
    uc:setCallback(on_message)
    local sf = hs.screen.mainScreen():frame()
    local w, h = 900, 600
    _wv = hs.webview.new({ x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h },
                         { developerExtrasEnabled = false }, uc)
    _wv:windowTitle("Flickwise — History")
    _wv:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    _wv:allowTextEntry(true)
    _wv:navigationCallback(function(action)
        if action == "didFinishNavigation" then refresh() end
    end)
    _wv:windowCallback(function(action)
        if action == "closing" then _wv = nil end
    end)
    _wv:html(HTML)
    focus()
end

function M.close()
    if _wv then
        local wv = _wv
        _wv = nil
        wv:delete()
    end
end

return M
