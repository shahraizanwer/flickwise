# Flickwise Architecture

How Flickwise is put together and how a fix flows through it. **Keep this file
current:** any change to behavior, modules, config keys, or data flow updates
this document in the same change (see `CLAUDE.md`).

_Last updated: 2026-09-27 (direct replace: read and write the selection through Accessibility, with no clipboard)._

---

## Runtime

- Runs entirely inside **Hammerspoon** (Lua 5.4). There is no build step. Hammerspoon loads `~/.hammerspoon/init.lua`, which runs `require("flickwise")`, and that loads `flickwise/init.lua`.
- UI surfaces (the pill, the picker, the diff bubble and the radial menu) are borderless, **non-activating** `hs.webview` windows, so the app you are typing in keeps focus. The HTML, CSS and JS for each one live inline in its Lua module.
- Keyboard input for the popups comes from short-lived `hs.eventtap`s, never from giving focus to a webview.
- AI backends: **Gemini** over HTTP (`ai_client.lua`) or the **Glean CLI** (`glean_client.lua`). The backend is Glean when `glean_binary_path` is set, otherwise Gemini.

## Module map

| Module | Role |
|---|---|
| `init.lua` | Entrypoint. Loads modules (each through `pcall`), loads config, `apply_config()` pushes config into every module, wires callbacks (reload, editor, settings, quit), and starts the file watcher. |
| `lib/config_loader.lua` | Parses `config.yaml` (via `tinyyaml`), validates it, and returns a normalized config table (see "Config shape"). |
| `lib/features.lua` | **Single source of truth for optional features.** Holds defaults, normalizes `features:` from YAML, provides the menu list, and rewrites `features.<key>.enabled` in `config.yaml`. |
| `lib/hotkey_manager.lua` | Binds a global hotkey for each mode, which calls `text_replacer.run`. |
| `lib/text_replacer.lua` | Core flow: capture the selection → call the backend → replace the selection → sound, HUD and diff bubble. Tries direct (Accessibility) first, then falls back to ⌘C/⌘V. Guards against overlapping runs (`_in_flight`). |
| `lib/ax_text.lua` | Accessibility text I/O (`features.direct_replace`): reads `AXSelectedText` and its range, detects web content, writes with `AXSelectedText` and verifies the write, and `restore()` for undo. |
| `lib/ai_client.lua` / `lib/glean_client.lua` | `transform(text, mode, cfg, on_ok, on_err)`, async. `ai_client` trims the output and strips wrapping quotes. |
| `lib/hud.lua` | Bottom-center status pill (working, done, error, info). An optional resting "idle" pill is controlled by `features.idle_pill`. |
| `lib/diff_bubble.lua` | "What changed" card above the pill with a word diff and undo (`features.diff_bubble`). |
| `lib/word_diff.lua` | Pure-Lua word-level diff: tokenize, trim the common prefix and suffix, run LCS, and group edits. No AI call. |
| `lib/radial_menu.lua` | Hold-and-flick ring of modes at the pointer (`features.radial_menu`). Applies through `text_replacer.run`. |
| `lib/mode_picker.lua` | ⌘⇧P command palette above the pill. Captures the selection, then calls `text_replacer.run_with_text`. |
| `lib/menubar_ui.lua` | Menu bar icon and menu: modes, Edit Modes, the **Features** submenu (toggles), and Advanced. |
| `lib/prompt_editor.lua` | "Edit Modes…" window. Edits `config.yaml` line by line (update prompt, add mode, delete mode). |
| `lib/setup_wizard.lua` | First-run Gemini API key wizard. Writes `gemini_api_key` and `gemini_model`. |
| `lib/watcher.lua` | Watches `config.yaml` and calls `callbacks.reload` 500 ms after the last change. |
| `lib/notifier.lua` | Log file (`flickwise.log`), macOS notifications, and a debug flag. |
| `lib/tinyyaml.lua` | Vendored YAML subset parser (maps, lists, flow arrays `[a, b]`, block scalars `|`, and `#` comments). Flow maps `{}` are **not** supported. |

## Fix flow (hotkey → replaced text)

```
hotkey ─► text_replacer.run(mode, cfg)
            ├─ diff_bubble.dismiss()            (a new run always closes an old bubble)
            ├─ capture_direct(): ax_text.read_selection()   (direct_replace on, app not excluded)
            │    └─ got text → dispatch(text, nil, mode, cfg, ax_ctx)       (no ⌘C, clipboard untouched)
            ├─ else: save clipboard, send ⌘C, poll the clipboard (up to 3 s)
            │    └─ fallback: AXSelectedText (text only)
            └─ dispatch()
                 ├─ hud.working(mode.name)
                 ├─ client.transform(...)  (async)
                 └─ on success:
                      ├─ result == original → nothing written, hud.success("No changes needed")
                      ├─ ax_ctx and can_write → ax_text.replace()        (direct, verified)
                      │    ├─ "selection changed while working" → result → clipboard, error, stop
                      │    └─ other failure → paste fallback
                      ├─ paste fallback: clipboard ← result, ⌘V, restore the clipboard
                      ├─ play a sound (defaults.sound)
                      └─ hud.success("Done", time)
                           + diff_bubble.show(original, result, mode, focused window, ax_ctx if direct)
                             (skipped if the feature is off or the mode sets diff_bubble: false)
```

The picker path is the same after capture: `mode_picker` tries `text_replacer.capture_direct()` first (with no ⌘C), then its own ⌘C capture, and then calls `text_replacer.run_with_text(..., ax_ctx)`.
The radial menu captures nothing itself. When the trigger is released it calls `text_replacer.run(mode, cfg)`, so the capture happens after the trigger key is already up.

## "What changed" bubble + undo (`lib/diff_bubble.lua`)

- **Diff:** `word_diff.diff(original, result)` returns segments of type `eq`, `del` or `ins`. A token is a word (letters, digits and any UTF-8 byte, so Urdu works; `'` and `-` inside a word are kept), a single punctuation mark, or a run of whitespace. Whitespace between two edits joins the edit, so each change shows as one struck-out run followed by one inserted run. When the middle section would need more than 250k LCS cells, it is shown as one replacement. Long unchanged stretches are collapsed to `context_words` words on each side, with `…` between.
- **Showing:** the page reports its height **synchronously** (a hidden webview never fires `requestAnimationFrame`). Lua then sizes the window, shows it, and calls `enter()` to animate it in. The countdown starts at this point, not when the diff is computed. It sits 50 px above the bottom, the same spot as the picker.
- **Countdown:** auto-dismisses after `duration_seconds`. A 3 px bar at the bottom of the card drains to show the time left. Lua owns the clock (`_session.total`, `remaining`, and `started`, which is nil while paused) and calls the page's `countdown(remaining, total, running)`. That sets the CSS animation with a negative delay, so the bar always matches the timer and never jumps.
- **Hover to hold:** Lua polls `hs.mouse.absolutePosition()` every 0.1 s against the card's rectangle, because a non-activating webview doesn't reliably receive `mouseenter`/`mouseleave`. With the pointer over the card, the countdown pauses: the bar freezes and turns grey, and the footer says "Paused while you read". When the pointer leaves, it resumes from exactly the remaining time.
- **Dismissal:** while the bubble is visible, an `hs.eventtap` (keyDown and leftMouseDown) is running:
  - undo hotkey (with an exact modifier match) and the same window focused → **undo**
  - any other key → dismiss and pass the key through (the user kept typing, so the undo is no longer ours)
  - a click outside the bubble → dismiss
- **Undo methods** (`undo_method`):
  - `app` (default): the app's own undo reverses the paste. If the undo hotkey is exactly ⌘Z, the user's key is **passed through** to the app. Otherwise it is swallowed and a synthetic ⌘Z is sent.
  - `reselect`: sends shift+← once per character of the result (`utf8.len`), then pastes the original through the clipboard and restores the clipboard. Results over 2000 characters fall back to `app`. This works in apps where ⌘Z doesn't cleanly undo a paste, but it can be off by a few characters with combined emoji (grapheme clusters).
  - `direct` (automatic, not a setting): when the fix was written through Accessibility, undo uses `ax_text.restore()` instead of either method above.
  - The tap is always stopped **before** synthetic keys are sent, so it never sees them. Clicking "Undo" in the bubble refocuses the original window first.

## Direct replace, without the clipboard (`lib/ax_text.lua`)

- **Read:** the focused element's `AXSelectedText` and `AXSelectedTextRange`. Secure fields, excluded apps (`exclude_apps`) and empty selections return nil, which means the clipboard path is used. `writable` means `AXSelectedText` is settable and a range is known. `web` means the element is inside an `AXWebArea` (or has `AXDOMIdentifier`/`AXDOMClassList`), found by walking up to 40 parents.
- **Web content** (browsers, Electron apps like Slack or VS Code): with `web_content: "paste"` (the default), the text is still *read* directly, but it's *written* with a paste. Setting `AXSelectedText` in a web page changes the DOM without input events, so frameworks such as React keep the old value.
- **Write:** `replace()` first makes sure the captured range still holds the captured text (it reselects if needed). If the text differs, the user edited it while the AI was working, so the result goes to the clipboard with an error instead of overwriting anything. It then sets `AXSelectedText` and verifies: `AXValue` changed and contains the result (or, without `AXValue`, `AXNumberOfCharacters` changed as expected). "The app ignored the write" means a paste fallback. "Changed but not verbatim" (e.g. normalized line endings) counts as success, so the text is never inserted twice.
- **Ranges** are UTF-16 code units (`ax_text.u16len`). After a replace, `ctx.new_range` = `{location, u16len(result)}`.
- **Undo:** for a direct replacement, the diff bubble never passes ⌘Z through to the app (its undo stack may not include the write). `restore()` selects `new_range`, checks that it still holds the result, writes the original back, and reselects the original. If that fails, the original is copied to the clipboard with an error.

## Radial menu (`lib/radial_menu.lua`)

- **Triggers** (`trigger`):
  - **Right-hand modifier** (`right_option` by default, or `right_command`, `right_control`, `right_shift`): a persistent `flagsChanged` tap tells left from right by the device-dependent bit in `rawFlags()` (Right ⌥ is keycode 61, mask `0x40`). It never swallows modifier events. On press, with no other modifier held, a session starts in the **pending** state. The ring opens only after `hold_ms` (150 ms). Releasing before that is a tap and does nothing. Any key press or other modifier while pending cancels it and passes through, so ⌥-characters still type.
  - **Chord** (e.g. `["ctrl", "alt", "space"]`): `hs.hotkey.bind` with pressed (open immediately) and released (apply) callbacks. Auto-repeat of the chord key is swallowed while open.
- **Session tap** (only while pending or open): keyDown, mouseMoved, leftMouseDragged, leftMouseDown and rightMouseDown.
  - Moving the pointer highlights the slot nearest the angle from the **press point**, outside a 28 px dead zone. The hub arrow rotates to follow it.
  - Releasing the trigger applies the highlighted slot. Releasing in the dead zone cancels.
  - Left-click applies the highlighted slot. Right-click or esc cancels.
  - `1`–`8` apply that slot directly. Any other key cancels and passes through.
- **Slots:** `modes` (a list of names) sets the order. When it's empty, the first 8 modes are used in config order. Slot 1 is at the top and the rest go clockwise at equal angles, so directions stay stable (muscle memory). Pills sit on a slightly flattened ring (`SQUASH` = 0.78). Pills on the right are anchored by their left edge and pills on the left by their right edge, so long names never overlap.
- **Anchor:** `mouse` (default) or `caret`. Caret mode reads `AXSelectedTextRange` and then `AXBoundsForRange` and falls back to the mouse. Direction is always measured from where the pointer was at press time, so flicks work the same for both anchors. The window (540×340) is clamped onto the screen.
- **Rendering:** the webview is preloaded in `configure()` so the first hold opens instantly. `render()` runs while the window is hidden, and `enter()` runs after `show()`, because a hidden webview never fires rAF. Pills spring out from the hub with a 30 ms stagger (`--i`). On apply, the chosen pill pops and the ring fades. `text_replacer.run` fires 60 ms later.
- It won't open while a run is in flight, and opening it dismisses the diff bubble.

## Config shape

`config.yaml` → `config_loader.load` returns:

```lua
{
  use_glean, glean_binary_path, gemini_api_key, gemini_model, has_api_key,
  defaults = { timeout_seconds, debug, sound },
  debug, picker_hotkey,
  modes = { { name, hotkey, system_prompt, timeout_seconds, diff_bubble } },
  features = {                     -- from features.normalize(), always fully populated
    idle_pill   = { enabled },
    diff_bubble = { enabled, duration_seconds, undo_hotkey, undo_method, context_words },
    radial_menu = { enabled, trigger (string | chord list), hold_ms, anchor, modes },
    direct_replace = { enabled, web_content ("paste" | "direct"), exclude_apps },
  },
}
```

### Feature flags (the rule for new features)

1. Add defaults to `features.DEFAULTS` (and a `features.MENU` entry if it should be toggleable from the menu bar).
2. Add the documented block under `features:` in **both** `config.yaml` and `config.example.yaml`.
3. The module exposes `configure(settings)`, and `init.lua`'s `apply_config()` calls it with `config.features.<key>`.
4. Per-mode opt-outs are plain keys on the mode (like `diff_bubble: false`), parsed in `config_loader`.

`features.normalize` fills in defaults, warns in the log about unknown keys or wrong types (settings listed in `FLEXIBLE` may take more than one type, like `radial_menu.trigger`), and accepts the shorthand `feature: false`. The menu's **Features** submenu calls `features.set_enabled`, which rewrites a single `enabled:` line (keeping comments and their column). The watcher then reloads the config, so there is no separate state (the old `hs.settings` idle-pill flag was removed).

### YAML layout constraint

`prompt_editor` finds mode blocks by `  - name:` lines and **appends new modes at the end of the file**, so top-level sections such as `features:` must stay **above** `modes:`. `features.set_enabled` inserts a missing `features:` block right before `modes:`.

## Screens and layering

| Surface | Window level | Position |
|---|---|---|
| HUD pill | `overlay` | bottom-center, flush with the bottom of the visible frame |
| Mode picker | `popUpMenu` | 50 px above the bottom, 400 px wide |
| Diff bubble | `popUpMenu` | 50 px above the bottom, 560 px wide |
| Radial menu | `popUpMenu` | centered on the pointer (or caret), 540×340, clamped to the screen |

The picker and the bubble never show together: opening the picker is a key press, which dismisses the bubble, and every run calls `diff_bubble.dismiss()`.

## Install & distribution (`install.sh`)

The repo is public at `github.com/shahraizanwer/flickwise` and **is** the install folder: `~/.hammerspoon/flickwise` is a git clone. The supported way to install or update is:
`curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/install.sh | bash`. `install.command` is a Finder double-click wrapper around it. The installer is idempotent and non-interactive (it's piped from curl, so there are no prompts):

1. Checks macOS 12+ and git, and installs Hammerspoon with `brew install --cask` if it's missing.
2. Code: an existing clone runs `git pull --ff-only` (skipped when there are local changes). An existing non-git folder is moved to `flickwise.backup.<ts>` (its `config.yaml` is kept). Otherwise it runs `git clone`.
3. TextFixer migration: copies `textfixer/config.yaml` if Flickwise has none, moves `textfixer/` and `~/Applications/TextFixer.app` to `textfixer.backup.<ts>`, and removes `require("textfixer")` from `init.lua` (backed up first).
4. Config: creates it from `config.example.yaml` if missing. An old config without `features:` gets the example's features block inserted above `modes:` (backed up first). `config.yaml` is never overwritten otherwise.
5. Ensures `hs.ipc.cliInstall()` and `require("flickwise")` are in `~/.hammerspoon/init.lua`.
6. Builds the `~/Applications/Flickwise.app` Spotlight launcher (opens `hammerspoon://flickwise-open`, with an icon from `assets/flickwise-icon-1024.png`).
7. Reloads Hammerspoon (`hs -c`, or quits and relaunches it, or launches it).

Environment overrides (`FLICKWISE_REPO`, `FLICKWISE_BRANCH`, `FLICKWISE_HS_DIR`, `FLICKWISE_APPS_DIR`, `FLICKWISE_SKIP_HAMMERSPOON`) let it be tested in a sandbox. `config.yaml`, `*.log` and `*.backup.*` are git-ignored.

## Files on disk

- `config.yaml` is user config (hot-reloaded, git-ignored, holds the API key). `config.example.yaml` is the committed template, with an empty key.
- `flickwise.log` is the runtime log (`notifier`).
- `IDEAS.md` is the roadmap. Tick items and move them to **Done** when they ship.
