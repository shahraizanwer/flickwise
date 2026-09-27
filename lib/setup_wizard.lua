-- setup_wizard.lua — first-run onboarding: collect and validate Gemini API key
-- Public API:
--   M.open(config_path, on_complete_callback)
--   M.close()

local M = {}

local _webview     = nil
local _usercontent = nil

-- ── YAML key writer ───────────────────────────────────────────────────────────

local function write_yaml_value(content, yaml_key, value)
    local escaped = value:gsub('"', '\\"')
    local new_content, n = content:gsub(
        '(' .. yaml_key .. ':%s*)[^\n]*',
        yaml_key .. ': "' .. escaped .. '"',
        1
    )
    if n == 0 then
        local lines = {}
        for line in (content .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(lines, line)
        end
        local insert_at = 1
        for i, line in ipairs(lines) do
            if not line:match("^%s*#") and not line:match("^%s*$") then
                insert_at = i; break
            end
        end
        table.insert(lines, insert_at, yaml_key .. ': "' .. escaped .. '"')
        new_content = table.concat(lines, "\n")
    end
    return new_content
end

local function write_api_key_and_model(config_path, api_key, model)
    local f = io.open(config_path, "r")
    if not f then return false, "Cannot read " .. config_path end
    local content = f:read("*a")
    f:close()

    content = write_yaml_value(content, "gemini_api_key", api_key)
    if model and model ~= "" then
        content = write_yaml_value(content, "gemini_model", model)
    end

    local f2 = io.open(config_path, "w")
    if not f2 then return false, "Cannot write " .. config_path end
    f2:write(content)
    f2:close()
    return true
end

-- ── HTML ──────────────────────────────────────────────────────────────────────

local function build_html()
    return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body {
  width: 100%; height: 100%;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  background: #1c1c1e; color: #f2f2f7;
  display: flex; align-items: center; justify-content: center;
  user-select: none;
}
.panel {
  display: none; flex-direction: column; align-items: center;
  text-align: center; gap: 18px; padding: 40px 48px;
  width: 100%; max-width: 480px;
}
.panel.active { display: flex; }
.icon { font-size: 52px; line-height: 1; }
h1 { font-size: 22px; font-weight: 700; color: #f2f2f7; }
.subtitle { font-size: 14px; color: #8e8e93; line-height: 1.6; max-width: 360px; }
.subtitle a { color: #0a84ff; text-decoration: none; }
.actions { display: flex; flex-direction: column; gap: 10px; width: 100%; max-width: 300px; }
button {
  width: 100%; padding: 10px 20px; border-radius: 8px; font-size: 14px;
  font-weight: 500; cursor: pointer; border: none;
  transition: background 0.15s, opacity 0.15s;
}
button:disabled { opacity: 0.4; cursor: default; }
.btn-primary { background: #0a84ff; color: #fff; }
.btn-primary:hover:not(:disabled) { background: #0071e3; }
.btn-secondary { background: #3a3a3c; color: #d1d1d6; }
.btn-secondary:hover:not(:disabled) { background: #48484a; }
.input-wrap { width: 100%; max-width: 360px; position: relative; }
input[type=password], input[type=text] {
  width: 100%; padding: 10px 42px 10px 12px; border-radius: 8px;
  background: #2c2c2e; border: 1.5px solid #3a3a3c; color: #e5e5ea;
  font-size: 13px; font-family: "SF Mono", monospace; outline: none;
  transition: border-color 0.15s; user-select: text;
}
input:focus { border-color: #0a84ff; }
.toggle-vis {
  position: absolute; right: 10px; top: 50%; transform: translateY(-50%);
  background: none; border: none; color: #636366; cursor: pointer;
  font-size: 15px; width: auto; padding: 0;
}
.msg { font-size: 13px; min-height: 20px; }
.msg.err  { color: #ff453a; }
.msg.ok   { color: #32d74b; }
.spinner {
  width: 20px; height: 20px; border: 2.5px solid #3a3a3c;
  border-top-color: #0a84ff; border-radius: 50%;
  animation: spin 0.7s linear infinite; display: none;
}
@keyframes spin { to { transform: rotate(360deg); } }
.hotkey-badge {
  background: #2c2c2e; border: 1px solid #3a3a3c; border-radius: 8px;
  padding: 12px 20px; font-size: 13px; color: #aeaeb2;
}
.hotkey-badge strong { font-size: 20px; color: #f2f2f7; display: block; margin-bottom: 4px; }
</style>
</head>
<body>

<!-- Panel 1: Welcome -->
<div class="panel active" id="p1">
  <div class="icon">✨</div>
  <h1>Welcome to Flickwise</h1>
  <p class="subtitle">
    Flickwise uses <strong style="color:#f2f2f7">Google Gemini AI</strong> to fix grammar,
    translate, and transform your text — completely free, no subscription needed.
    <br><br>
    You'll need a free API key from Google AI Studio. It takes about 30 seconds.
  </p>
  <div class="actions">
    <button class="btn-primary" onclick="openKey()">Get Your Free API Key →</button>
    <button class="btn-secondary" onclick="showPanel(2)">I already have a key</button>
  </div>
</div>

<!-- Panel 2: Enter key -->
<div class="panel" id="p2">
  <div class="icon">🔑</div>
  <h1>Enter Your API Key</h1>
  <p class="subtitle">Paste your Gemini API key below.</p>
  <div class="input-wrap">
    <input type="password" id="keyInput" placeholder="Paste your API key…" autocomplete="off" spellcheck="false" />
    <button class="toggle-vis" id="toggleBtn" onclick="toggleVis()" title="Show/hide">👁</button>
  </div>
  <p class="subtitle" style="margin-top:4px;font-size:12px;">Model name <span style="color:#636366">(free tier — <a href="#" onclick="openModels()">see options</a>)</span></p>
  <div class="input-wrap">
    <input type="text" id="modelInput" value="gemini-flash-latest" autocomplete="off" spellcheck="false" style="font-family:monospace;padding-right:12px;" />
  </div>
  <div class="spinner" id="spinner"></div>
  <div class="msg" id="keyMsg"></div>
  <div class="actions">
    <button class="btn-primary" id="testBtn" onclick="testKey()">Test &amp; Save</button>
    <button class="btn-secondary" onclick="showPanel(1)">← Back</button>
  </div>
</div>

<!-- Panel 3: Done -->
<div class="panel" id="p3">
  <div class="icon">🎉</div>
  <h1>You're All Set!</h1>
  <p class="subtitle">Flickwise is ready. Select any text, then use a hotkey to transform it instantly.</p>
  <div class="hotkey-badge">
    <strong id="firstHotkey">⌘⇧G</strong>
    Fix Grammar
  </div>
  <p class="subtitle" style="font-size:12px;color:#636366">
    Press <strong style="color:#aeaeb2">⌘⇧P</strong> anytime to pick from all modes.
  </p>
  <div class="actions">
    <button class="btn-primary" onclick="done()">Done</button>
    <button class="btn-secondary" onclick="openEditor()">Manage Modes…</button>
  </div>
</div>

<script>
function showPanel(n) {
  document.querySelectorAll('.panel').forEach(function(p) { p.classList.remove('active'); });
  document.getElementById('p' + n).classList.add('active');
  if (n === 2) { setTimeout(function() { document.getElementById('keyInput').focus(); }, 80); }
}

function openKey() {
  window.webkit.messageHandlers.flickwise.postMessage({
    action: 'open_url', url: 'https://aistudio.google.com/app/apikey'
  });
  showPanel(2);
}

function openModels() {
  window.webkit.messageHandlers.flickwise.postMessage({
    action: 'open_url', url: 'https://ai.google.dev/gemini-api/docs/models'
  });
}

function toggleVis() {
  var inp = document.getElementById('keyInput');
  inp.type = inp.type === 'password' ? 'text' : 'password';
}

document.addEventListener('keydown', function(e) {
  if (e.key === 'Enter') {
    var p2 = document.getElementById('p2');
    if (p2.classList.contains('active')) testKey();
  }
});

function testKey() {
  var key   = document.getElementById('keyInput').value.trim();
  var model = document.getElementById('modelInput').value.trim() || 'gemini-flash-latest';
  var msg   = document.getElementById('keyMsg');
  if (!key) { showMsg('Please enter your API key', true); return; }

  var testBtn = document.getElementById('testBtn');
  var spinner = document.getElementById('spinner');
  testBtn.disabled = true;
  spinner.style.display = 'block';
  msg.textContent = '';
  msg.className = 'msg';

  window.webkit.messageHandlers.flickwise.postMessage({ action: 'test_key', key: key, model: model });
}

function handleTestResult(success, errMsg) {
  var testBtn = document.getElementById('testBtn');
  var spinner = document.getElementById('spinner');
  testBtn.disabled = false;
  spinner.style.display = 'none';

  if (success) {
    showMsg('✓ Key is valid!', false);
    var key   = document.getElementById('keyInput').value.trim();
    var model = document.getElementById('modelInput').value.trim() || 'gemini-flash-latest';
    window.webkit.messageHandlers.flickwise.postMessage({ action: 'save_key', key: key, model: model });
    setTimeout(function() { showPanel(3); }, 600);
  } else {
    showMsg(errMsg || 'Invalid key — please try again', true);
  }
}

function showMsg(text, isErr) {
  var msg = document.getElementById('keyMsg');
  msg.textContent = text;
  msg.className = 'msg ' + (isErr ? 'err' : 'ok');
}

function done() {
  window.webkit.messageHandlers.flickwise.postMessage({ action: 'close' });
}

function openEditor() {
  window.webkit.messageHandlers.flickwise.postMessage({ action: 'open_editor' });
}
</script>
</body>
</html>]]
end

-- ── public API ────────────────────────────────────────────────────────────────

function M.open(config_path, on_complete)
    if _webview then
        if _webview:isVisible() then _webview:bringToFront() return end
        _webview:delete(); _webview = nil
    end

    local ai_client = require("flickwise.lib.ai_client")

    _usercontent = hs.webview.usercontent.new("flickwise")
    _usercontent:setCallback(function(message)
        local data = message.body
        if type(data) ~= "table" then return end

        if data.action == "open_url" then
            hs.urlevent.openURL(data.url)

        elseif data.action == "test_key" then
            local key   = tostring(data.key   or "")
            local model = tostring(data.model or "gemini-flash-latest")
            ai_client.test_key(key, model, function(ok, err)
                if _webview then
                    local safe_err = (err or ""):gsub("'", "\\'"):gsub('"', '\\"')
                    local js = string.format("handleTestResult(%s, '%s')",
                        ok and "true" or "false", safe_err)
                    _webview:evaluateJavaScript(js)
                end
            end)

        elseif data.action == "save_key" then
            local key   = tostring(data.key   or "")
            local model = tostring(data.model or "gemini-flash-latest")
            write_api_key_and_model(config_path, key, model)
            if on_complete then on_complete() end

        elseif data.action == "open_editor" then
            M.close()
            if on_complete then on_complete() end

        elseif data.action == "close" then
            M.close()
            if on_complete then on_complete() end
        end
    end)

    local screen = hs.screen.mainScreen():frame()
    local w, h   = 560, 460
    _webview = hs.webview.new(
        { x = screen.x + (screen.w - w) / 2,
          y = screen.y + (screen.h - h) / 2,
          w = w, h = h },
        { developerExtrasEnabled = false },
        _usercontent
    )
    _webview:windowTitle("Flickwise Setup")
    _webview:windowStyle({"titled", "closable"})
    _webview:allowTextEntry(true)
    _webview:html(build_html())
    _webview:show()
    _webview:bringToFront()
end

function M.close()
    if _webview then _webview:delete(); _webview = nil end
    _usercontent = nil
end

return M
