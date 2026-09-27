-- prompt_editor.lua — floating webview UI for editing, creating, and deleting modes
-- Public API: M.open(config, config_path, reload_callback), M.close()

local M = {}

local _webview     = nil
local _usercontent = nil

-- ── YAML helpers ──────────────────────────────────────────────────────────────

local function lua_array_to_yaml(t)
    local parts = {}
    for _, v in ipairs(t) do
        table.insert(parts, '"' .. tostring(v) .. '"')
    end
    return '[' .. table.concat(parts, ', ') .. ']'
end

local function update_yaml_prompt(path, mode_name, new_prompt)
    local f = io.open(path, "r")
    if not f then return false, "Cannot read " .. path end
    local content = f:read("*a")
    f:close()

    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end

    local escaped = mode_name:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    local mode_start
    for i, line in ipairs(lines) do
        if line:match('%-%s+name:%s*"' .. escaped .. '"')
        or line:match("%-%s+name:%s*'" .. escaped .. "'")
        or line:match("%-%s+name:%s+" .. escaped .. "%s*$") then
            mode_start = i
            break
        end
    end
    if not mode_start then
        return false, "Mode '" .. mode_name .. "' not found in config"
    end

    local mode_end = #lines + 1
    for i = mode_start + 1, #lines do
        if lines[i]:match("^  %- ") then
            mode_end = i
            break
        end
    end

    local prompt_header
    for i = mode_start, mode_end - 1 do
        if lines[i]:match("^%s+system_prompt:%s*|") then
            prompt_header = i
            break
        end
    end
    if not prompt_header then
        return false, "system_prompt not found for '" .. mode_name .. "'"
    end

    local prompt_body_end = prompt_header
    for i = prompt_header + 1, mode_end - 1 do
        if lines[i]:match("^      ") then
            prompt_body_end = i
        elseif lines[i]:match("^%s*$") then
            -- blank line — keep scanning
        else
            break
        end
    end

    new_prompt = new_prompt:gsub("\r\n", "\n"):gsub("\r", "\n")
    new_prompt = new_prompt:match("^(.-)%s*$") or new_prompt
    local new_lines = {}
    for line in (new_prompt .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(new_lines, "      " .. line)
    end

    local result = {}
    for i = 1, prompt_header do table.insert(result, lines[i]) end
    for _, line in ipairs(new_lines) do table.insert(result, line) end
    for i = prompt_body_end + 1, #lines do table.insert(result, lines[i]) end

    while #result > 0 and result[#result]:match("^%s*$") do
        table.remove(result)
    end

    local f2 = io.open(path, "w")
    if not f2 then return false, "Cannot write " .. path end
    f2:write(table.concat(result, "\n") .. "\n")
    f2:close()
    return true
end

local function add_yaml_mode(path, name, hotkey_array, system_prompt)
    local f = io.open(path, "r")
    if not f then return false, "Cannot read " .. path end
    local content = f:read("*a")
    f:close()

    local trimmed = system_prompt:gsub("\r\n", "\n"):gsub("\r", "\n")
    trimmed = trimmed:match("^(.-)%s*$") or trimmed
    local prompt_lines = {}
    for line in (trimmed .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(prompt_lines, "      " .. line)
    end

    local safe_name   = name:gsub('"', '\\"')
    local hotkey_yaml = lua_array_to_yaml(hotkey_array)
    local new_block   = "\n  - name: \"" .. safe_name .. "\"\n"
        .. "    hotkey: " .. hotkey_yaml .. "\n"
        .. "    system_prompt: |\n"
        .. table.concat(prompt_lines, "\n") .. "\n"

    local result = content:gsub("%s*$", "") .. new_block

    local f2 = io.open(path, "w")
    if not f2 then return false, "Cannot write " .. path end
    f2:write(result)
    f2:close()
    return true
end

local function delete_yaml_mode(path, mode_name)
    local f = io.open(path, "r")
    if not f then return false, "Cannot read " .. path end
    local content = f:read("*a")
    f:close()

    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end

    local escaped = mode_name:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    local mode_start
    for i, line in ipairs(lines) do
        if line:match('%-%s+name:%s*"' .. escaped .. '"')
        or line:match("%-%s+name:%s*'" .. escaped .. "'")
        or line:match("%-%s+name:%s+" .. escaped .. "%s*$") then
            mode_start = i
            break
        end
    end
    if not mode_start then
        return false, "Mode '" .. mode_name .. "' not found in config"
    end

    local mode_end = #lines + 1
    for i = mode_start + 1, #lines do
        if lines[i]:match("^  %- ") then
            mode_end = i
            break
        end
    end

    -- Also remove the blank line that precedes this mode block
    local delete_from = mode_start
    if delete_from > 1 and lines[delete_from - 1]:match("^%s*$") then
        delete_from = delete_from - 1
    end

    local result = {}
    for i, line in ipairs(lines) do
        if i < delete_from or i >= mode_end then
            table.insert(result, line)
        end
    end

    while #result > 0 and result[#result]:match("^%s*$") do
        table.remove(result)
    end

    local f2 = io.open(path, "w")
    if not f2 then return false, "Cannot write " .. path end
    f2:write(table.concat(result, "\n") .. "\n")
    f2:close()
    return true
end

-- ── HTML builder ──────────────────────────────────────────────────────────────

local MOD_GLYPHS = {
    cmd = "⌘", command = "⌘",
    shift = "⇧",
    ctrl = "⌃", control = "⌃",
    alt = "⌥", opt = "⌥", option = "⌥",
}

local function hotkey_label(hk)
    local parts = {}
    for _, p in ipairs(hk) do
        local g = MOD_GLYPHS[p:lower()]
        table.insert(parts, g or p:upper())
    end
    return table.concat(parts, "")
end

local function build_html(config)
    local mode_items = {}
    for _, mode in ipairs(config.modes) do
        table.insert(mode_items, {
            name          = mode.name,
            hotkey        = hotkey_label(mode.hotkey),
            system_prompt = mode.system_prompt,
        })
    end
    local modes_json = hs.json.encode(mode_items)

    return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  background: #1c1c1e; color: #f2f2f7;
  display: flex; height: 100vh; overflow: hidden; user-select: none;
}
#sidebar {
  width: 195px; background: #2c2c2e; border-right: 1px solid #3a3a3c;
  display: flex; flex-direction: column; flex-shrink: 0; overflow-y: auto;
}
#sidebar-header {
  display: flex; align-items: center; justify-content: space-between;
  padding: 16px 10px 10px 14px; flex-shrink: 0;
}
#sidebar-label {
  font-size: 10px; font-weight: 600; color: #48484a;
  text-transform: uppercase; letter-spacing: 0.09em;
}
#btn-add {
  width: 22px; height: 22px; border-radius: 5px; background: #3a3a3c;
  color: #aeaeb2; border: none; font-size: 18px; line-height: 1; cursor: pointer;
  display: flex; align-items: center; justify-content: center;
  padding-bottom: 1px; flex-shrink: 0; transition: background 0.12s, color 0.12s;
}
#btn-add:hover, #btn-add.active { background: #0a84ff; color: #fff; }
.mode-btn {
  position: relative; padding: 10px 8px 10px 17px; cursor: pointer;
  border-left: 3px solid transparent; flex-shrink: 0;
  display: flex; align-items: center; justify-content: space-between;
}
.mode-btn:hover { background: #363638; }
.mode-btn.active { background: #3a3a3c; border-left-color: #0a84ff; }
.mode-info { flex: 1; min-width: 0; }
.mode-name { font-size: 13px; color: #d1d1d6; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mode-hotkey { font-size: 11px; color: #48484a; margin-top: 2px; }
.mode-btn.active .mode-name { color: #fff; }
.mode-btn.active .mode-hotkey { color: #636366; }
.btn-del {
  width: 20px; height: 20px; border-radius: 4px; background: transparent;
  border: none; color: #636366; font-size: 15px; cursor: pointer;
  display: none; align-items: center; justify-content: center;
  flex-shrink: 0; margin-left: 4px; padding: 0;
  transition: background 0.1s, color 0.1s;
}
.mode-btn:hover .btn-del { display: flex; }
.btn-del:hover { background: #ff453a22; color: #ff453a; }
.btn-del.confirm { display: flex; color: #ff9f0a; background: #ff9f0a22; }
.btn-del:disabled { display: none !important; }
#main { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.view {
  flex: 1; display: flex; flex-direction: column;
  padding: 20px 20px 16px; gap: 12px; min-width: 0;
}
#view-create { display: none; }
.view-title { font-size: 15px; font-weight: 600; color: #f2f2f7; }
.view-hint { font-size: 12px; color: #48484a; }
.view-header { display: flex; flex-direction: column; gap: 4px; flex-shrink: 0; }
textarea {
  flex: 1; background: #2c2c2e; border: 1.5px solid #3a3a3c; border-radius: 8px;
  color: #e5e5ea; font-family: "SF Mono", "Menlo", monospace; font-size: 12px;
  line-height: 1.65; padding: 12px 14px; resize: none; outline: none;
  transition: border-color 0.15s; user-select: text;
}
textarea:focus { border-color: #0a84ff; }
textarea::placeholder { color: #48484a; }
textarea:disabled { opacity: 0.35; cursor: default; }
.view-footer { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
.status { flex: 1; font-size: 12px; color: #32d74b; }
.status.err { color: #ff453a; }
button {
  padding: 6px 16px; border-radius: 6px; font-size: 13px; font-weight: 500;
  cursor: pointer; border: none; transition: opacity 0.12s, background 0.12s;
}
button:disabled { opacity: 0.35; cursor: default; }
.btn-sec { background: #3a3a3c; color: #d1d1d6; }
.btn-sec:hover:not(:disabled) { background: #48484a; }
.btn-pri { background: #0a84ff; color: #fff; min-width: 110px; }
.btn-pri:hover:not(:disabled) { background: #0071e3; }
/* Create form */
#create-fields { display: flex; flex-direction: column; gap: 10px; flex-shrink: 0; }
.field-label {
  font-size: 10px; font-weight: 600; color: #636366;
  text-transform: uppercase; letter-spacing: 0.07em; margin-bottom: 5px;
}
#new-name {
  width: 100%; background: #2c2c2e; border: 1.5px solid #3a3a3c; border-radius: 6px;
  color: #e5e5ea; font-size: 13px; padding: 7px 10px; outline: none;
  transition: border-color 0.15s; user-select: text;
}
#new-name:focus { border-color: #0a84ff; }
#hotkey-row { display: flex; align-items: center; gap: 6px; }
.mod-btn {
  padding: 5px 9px; border-radius: 6px; font-size: 14px; cursor: pointer;
  border: 1.5px solid #3a3a3c; background: #2c2c2e; color: #636366;
  transition: border-color 0.12s, color 0.12s, background 0.12s;
}
.mod-btn.active { background: #0a84ff22; border-color: #0a84ff; color: #0a84ff; }
.mod-btn:hover:not(.active) { border-color: #636366; color: #aeaeb2; }
.hk-sep { color: #48484a; font-size: 13px; }
#new-key {
  width: 46px; background: #2c2c2e; border: 1.5px solid #3a3a3c; border-radius: 6px;
  color: #e5e5ea; font-size: 14px; text-align: center; padding: 5px 4px;
  outline: none; transition: border-color 0.15s; user-select: text; text-transform: uppercase;
}
#new-key:focus { border-color: #0a84ff; }
#hk-preview { font-size: 13px; color: #0a84ff; font-weight: 600; min-width: 50px; }
.prompt-wrap { flex: 1; display: flex; flex-direction: column; min-height: 0; }
</style>
</head>
<body>
<div id="sidebar">
  <div id="sidebar-header">
    <span id="sidebar-label">Modes</span>
    <button id="btn-add" title="Add new mode">+</button>
  </div>
</div>
<div id="main">
  <div id="view-edit" class="view">
    <div class="view-header">
      <div class="view-title" id="mode-title">Prompt Editor</div>
      <div class="view-hint" id="hint">Select a mode to edit its system prompt</div>
    </div>
    <textarea id="prompt-textarea" spellcheck="false" disabled
              placeholder="Select a mode on the left…"></textarea>
    <div class="view-footer">
      <span class="status" id="status"></span>
      <button class="btn-sec" id="btn-close">Close</button>
      <button class="btn-pri" id="btn-save" disabled>Save &amp; Reload</button>
    </div>
  </div>

  <div id="view-create" class="view">
    <div class="view-header">
      <div class="view-title">New Mode</div>
      <div class="view-hint">Define a new text transformation mode</div>
    </div>
    <div id="create-fields">
      <div>
        <div class="field-label">Mode name</div>
        <input type="text" id="new-name" placeholder="e.g. Translate to French" autocomplete="off" />
      </div>
      <div>
        <div class="field-label">Hotkey</div>
        <div id="hotkey-row">
          <button class="mod-btn" data-mod="cmd">⌘</button>
          <button class="mod-btn" data-mod="shift">⇧</button>
          <button class="mod-btn" data-mod="ctrl">⌃</button>
          <button class="mod-btn" data-mod="alt">⌥</button>
          <span class="hk-sep">+</span>
          <input type="text" id="new-key" maxlength="1" placeholder="K" autocomplete="off" />
          <span id="hk-preview"></span>
        </div>
      </div>
    </div>
    <div class="prompt-wrap">
      <div class="field-label">System prompt</div>
      <textarea id="new-prompt" spellcheck="false"
                placeholder="Instructions for the AI. Be specific about what to do with the selected text."></textarea>
    </div>
    <div class="view-footer">
      <span class="status" id="create-status"></span>
      <button class="btn-sec" id="btn-cancel">Cancel</button>
      <button class="btn-pri" id="btn-create">Create Mode</button>
    </div>
  </div>
</div>
<script>
const MOD_GLYPHS = { cmd: '⌘', shift: '⇧', ctrl: '⌃', alt: '⌥' };
const MOD_ORDER  = ['cmd', 'shift', 'ctrl', 'alt'];

let modes      = ]] .. modes_json .. [[;
let current    = null;
let currentRow = null;

// DOM refs
const sidebar     = document.getElementById('sidebar');
const viewEdit    = document.getElementById('view-edit');
const viewCreate  = document.getElementById('view-create');
const btnAdd      = document.getElementById('btn-add');
const titleEl     = document.getElementById('mode-title');
const hintEl      = document.getElementById('hint');
const textarea    = document.getElementById('prompt-textarea');
const btnSave     = document.getElementById('btn-save');
const btnClose    = document.getElementById('btn-close');
const statusEl    = document.getElementById('status');
const newNameEl   = document.getElementById('new-name');
const newKeyEl    = document.getElementById('new-key');
const hkPreview   = document.getElementById('hk-preview');
const newPromptEl = document.getElementById('new-prompt');
const createSt    = document.getElementById('create-status');
const btnCreate   = document.getElementById('btn-create');
const btnCancel   = document.getElementById('btn-cancel');

// ── View switching ────────────────────────────────────────────────────────────
function showEdit() {
  viewEdit.style.display  = 'flex';
  viewCreate.style.display = 'none';
  btnAdd.classList.remove('active');
}
function showCreate() {
  viewEdit.style.display   = 'none';
  viewCreate.style.display = 'flex';
  btnAdd.classList.add('active');
  document.querySelectorAll('.mode-btn').forEach(b => b.classList.remove('active'));
  newNameEl.value  = '';
  newKeyEl.value   = '';
  newPromptEl.value = '';
  activeMods.clear();
  document.querySelectorAll('.mod-btn').forEach(b => b.classList.remove('active'));
  hkPreview.textContent   = '';
  createSt.textContent    = '';
  createSt.className      = 'status';
  setTimeout(() => newNameEl.focus(), 50);
}

// ── Sidebar ───────────────────────────────────────────────────────────────────
let pendingDel = null;
let delTimer   = null;

function addModeRow(mode) {
  const row    = document.createElement('div');
  row.className = 'mode-btn';

  const info   = document.createElement('div');
  info.className = 'mode-info';

  const nameDiv = document.createElement('div');
  nameDiv.className = 'mode-name';
  nameDiv.textContent = mode.name;

  const hkDiv = document.createElement('div');
  hkDiv.className = 'mode-hotkey';
  hkDiv.textContent = mode.hotkey;

  const delBtn = document.createElement('button');
  delBtn.className = 'btn-del';
  delBtn.title = 'Delete mode (click twice to confirm)';
  delBtn.textContent = '×';

  info.appendChild(nameDiv);
  info.appendChild(hkDiv);
  row.appendChild(info);
  row.appendChild(delBtn);
  sidebar.appendChild(row);

  row.addEventListener('click', function(e) {
    if (e.target === delBtn) return;
    selectMode(mode, row);
    showEdit();
  });

  delBtn.addEventListener('click', function(e) {
    e.stopPropagation();
    handleDelClick(mode.name, row, delBtn);
  });

  return row;
}

function buildSidebar() {
  sidebar.querySelectorAll('.mode-btn').forEach(function(b) { b.remove(); });
  modes.forEach(function(mode) { addModeRow(mode); });
  refreshDelButtons();
}

function refreshDelButtons() {
  sidebar.querySelectorAll('.btn-del').forEach(function(btn) {
    btn.disabled = modes.length <= 1;
  });
}

// ── Mode selection ────────────────────────────────────────────────────────────
function selectMode(mode, row) {
  document.querySelectorAll('.mode-btn').forEach(function(b) { b.classList.remove('active'); });
  if (row) { row.classList.add('active'); currentRow = row; }
  current              = mode;
  titleEl.textContent  = mode.name;
  hintEl.textContent   = 'Edit the system prompt, then click Save & Reload';
  textarea.value       = mode.system_prompt;
  textarea.disabled    = false;
  btnSave.disabled     = false;
  statusEl.textContent = '';
  statusEl.className   = 'status';
}

// ── Delete (two-click confirm) ────────────────────────────────────────────────
function handleDelClick(modeName, row, btn) {
  if (btn.disabled) return;
  if (pendingDel === modeName) {
    clearTimeout(delTimer);
    pendingDel = null;
    btn.textContent = '×';
    btn.classList.remove('confirm');
    doDelete(modeName, row);
  } else {
    if (pendingDel) {
      sidebar.querySelectorAll('.btn-del.confirm').forEach(function(b) {
        b.textContent = '×';
        b.classList.remove('confirm');
      });
      clearTimeout(delTimer);
    }
    pendingDel = modeName;
    btn.textContent = '?';
    btn.classList.add('confirm');
    delTimer = setTimeout(function() {
      pendingDel = null;
      btn.textContent = '×';
      btn.classList.remove('confirm');
    }, 2000);
  }
}

function doDelete(modeName, row) {
  var idx = -1;
  for (var i = 0; i < modes.length; i++) {
    if (modes[i].name === modeName) { idx = i; break; }
  }
  if (idx === -1) return;
  modes.splice(idx, 1);
  row.remove();
  refreshDelButtons();

  if (current && current.name === modeName) {
    var firstRow = sidebar.querySelector('.mode-btn');
    if (firstRow && modes.length > 0) {
      selectMode(modes[0], firstRow);
    } else {
      current              = null;
      currentRow           = null;
      titleEl.textContent  = 'Prompt Editor';
      hintEl.textContent   = 'Select a mode to edit its system prompt';
      textarea.value       = '';
      textarea.disabled    = true;
      btnSave.disabled     = true;
    }
    showEdit();
  }

  flashStatus('Deleted ✓', false);
  window.webkit.messageHandlers.flickwise.postMessage({
    action: 'delete', modeName: modeName
  });
}

// ── Create flow ───────────────────────────────────────────────────────────────
var activeMods = new Set();

document.querySelectorAll('.mod-btn').forEach(function(btn) {
  btn.addEventListener('click', function() {
    var mod = btn.dataset.mod;
    if (activeMods.has(mod)) {
      activeMods.delete(mod);
      btn.classList.remove('active');
    } else {
      activeMods.add(mod);
      btn.classList.add('active');
    }
    updateHkPreview();
  });
});

newKeyEl.addEventListener('input', function() {
  newKeyEl.value = newKeyEl.value.slice(-1);
  updateHkPreview();
});

function updateHkPreview() {
  var key   = newKeyEl.value.toLowerCase();
  var parts = MOD_ORDER.filter(function(m) { return activeMods.has(m); })
                       .map(function(m) { return MOD_GLYPHS[m]; });
  if (key) parts.push(key.toUpperCase());
  hkPreview.textContent = parts.join('');
}

btnCreate.addEventListener('click', function() {
  var name   = newNameEl.value.trim();
  var key    = newKeyEl.value.trim().toLowerCase();
  var prompt = newPromptEl.value.trim();

  if (!name)   { flashCreate('Mode name is required', true); return; }

  var dup = false;
  for (var i = 0; i < modes.length; i++) {
    if (modes[i].name.toLowerCase() === name.toLowerCase()) { dup = true; break; }
  }
  if (dup) { flashCreate('A mode with that name already exists', true); return; }

  if (activeMods.size === 0 || !key) {
    flashCreate('Select at least one modifier and a key letter', true); return;
  }
  if (!prompt) { flashCreate('System prompt is required', true); return; }

  var hotkey     = MOD_ORDER.filter(function(m) { return activeMods.has(m); });
  hotkey.push(key);
  var hotkeyLabel = hotkey.map(function(p) { return MOD_GLYPHS[p] || p.toUpperCase(); }).join('');

  var newMode = { name: name, hotkey: hotkeyLabel, system_prompt: prompt };
  modes.push(newMode);
  var newRow = addModeRow(newMode);
  refreshDelButtons();

  window.webkit.messageHandlers.flickwise.postMessage({
    action: 'create', name: name, hotkey: hotkey, prompt: prompt
  });

  showEdit();
  selectMode(newMode, newRow);
  flashStatus('Mode created ✓', false);
});

btnCancel.addEventListener('click', function() {
  if (current && currentRow) {
    selectMode(current, currentRow);
  } else if (modes.length > 0) {
    var firstRow = sidebar.querySelector('.mode-btn');
    if (firstRow) selectMode(modes[0], firstRow);
  }
  showEdit();
});

btnAdd.addEventListener('click', function() {
  if (viewCreate.style.display !== 'none') {
    // Toggle off — go back to edit
    if (current && currentRow) { selectMode(current, currentRow); }
    showEdit();
  } else {
    showCreate();
  }
});

// ── Save (edit) ───────────────────────────────────────────────────────────────
btnSave.addEventListener('click', function() {
  if (!current || btnSave.disabled) return;
  btnSave.disabled = true;
  window.webkit.messageHandlers.flickwise.postMessage({
    action: 'save', modeName: current.name, prompt: textarea.value
  });
  current.system_prompt = textarea.value;
  for (var i = 0; i < modes.length; i++) {
    if (modes[i].name === current.name) { modes[i].system_prompt = textarea.value; break; }
  }
  flashStatus('Saved & reloaded ✓', false);
  setTimeout(function() { btnSave.disabled = false; }, 1000);
});

btnClose.addEventListener('click', function() {
  window.webkit.messageHandlers.flickwise.postMessage({ action: 'close' });
});

// ── Flash helpers ─────────────────────────────────────────────────────────────
var statusTmr  = null;
var createTmr  = null;

function flashStatus(msg, isErr) {
  statusEl.textContent = msg;
  statusEl.className   = isErr ? 'status err' : 'status';
  if (statusTmr) clearTimeout(statusTmr);
  statusTmr = setTimeout(function() { statusEl.textContent = ''; }, 3000);
}

function flashCreate(msg, isErr) {
  createSt.textContent = msg;
  createSt.className   = isErr ? 'status err' : 'status';
  if (createTmr) clearTimeout(createTmr);
  if (!isErr) createTmr = setTimeout(function() { createSt.textContent = ''; }, 3000);
}

// ── Init ──────────────────────────────────────────────────────────────────────
buildSidebar();
if (modes.length > 0) {
  var firstRow = sidebar.querySelector('.mode-btn');
  selectMode(modes[0], firstRow);
}
</script>
</body>
</html>]]
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.open(config, config_path, reload_callback)
    if _webview then
        if _webview:isVisible() then
            _webview:bringToFront()
            return
        end
        _webview:delete()
        _webview = nil
    end

    _usercontent = hs.webview.usercontent.new("flickwise")
    _usercontent:setCallback(function(message)
        local data = message.body
        if type(data) ~= "table" then return end

        if data.action == "save" then
            local ok, err = update_yaml_prompt(config_path, data.modeName, data.prompt)
            if ok then
                reload_callback()
            else
                require("flickwise.lib.hud").error("Couldn't save — " .. (err or "unknown error"))
            end

        elseif data.action == "create" then
            if type(data.hotkey) ~= "table" or #data.hotkey < 2 then
                require("flickwise.lib.hud").error("Invalid hotkey for new mode")
                return
            end
            local ok, err = add_yaml_mode(config_path, data.name, data.hotkey, data.prompt)
            if ok then
                reload_callback()
            else
                require("flickwise.lib.hud").error("Couldn't create — " .. (err or "unknown error"))
            end

        elseif data.action == "delete" then
            local ok, err = delete_yaml_mode(config_path, data.modeName)
            if ok then
                reload_callback()
            else
                require("flickwise.lib.hud").error("Couldn't delete — " .. (err or "unknown error"))
            end

        elseif data.action == "close" then
            M.close()
        end
    end)

    local screen = hs.screen.mainScreen():frame()
    local w, h   = 720, 520
    _webview = hs.webview.new(
        { x = screen.x + (screen.w - w) / 2,
          y = screen.y + (screen.h - h) / 2,
          w = w, h = h },
        { developerExtrasEnabled = false },
        _usercontent
    )
    _webview:windowTitle("Flickwise — Prompt Editor")
    _webview:windowStyle({"titled", "closable", "resizable"})
    _webview:allowTextEntry(true)
    _webview:html(build_html(config))
    _webview:show()
    _webview:bringToFront()
end

function M.close()
    if _webview then
        _webview:delete()
        _webview = nil
    end
    _usercontent = nil
end

return M
