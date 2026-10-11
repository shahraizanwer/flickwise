# Flickwise Architecture

How Flickwise is put together and how a fix flows through it. **Keep this file
current:** any change to behavior, modules, config keys, or data flow updates
this document in the same change (see `CLAUDE.md`).

_Last updated: 2026-10-12 (One app: text fixes, modes, cards, picker, radial menu and fix history moved into the native app; Hammerspoon is retired by its installer)._

---

## Runtime

- **The native app (`macos/`) is Flickwise.** Since 2026-10-12 it does everything: dictation, every mode (text fixes, answers, replies), the cards, the picker, the radial menu, history and My Progress, all configurable in its window. `macos/install.sh` imports the Hammerspoon setup and comments out `require("flickwise")` in `~/.hammerspoon/init.lua`. The Lua sections below describe the Hammerspoon version, which still works on Macs that haven't installed the app (and is the reference the Swift port follows).
- The Hammerspoon part runs entirely inside **Hammerspoon** (Lua 5.4). There is no build step. Hammerspoon loads `~/.hammerspoon/init.lua`, which runs `require("flickwise")`, and that loads `flickwise/init.lua`.
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
| `lib/ax_text.lua` | Accessibility text I/O (`features.direct_replace`): reads `AXSelectedText` and its range, detects web content, writes with `AXSelectedText` and verifies the write, `restore()` for undo, and `insert_at_focus()` to type at the caret (Reply Helper). |
| `lib/ai_client.lua` / `lib/glean_client.lua` | `transform(text, mode, cfg, on_ok, on_err)`, async. `ai_client` trims the output and strips wrapping quotes. |
| `lib/hud.lua` | Bottom-center status pill (working, done, error, info). An optional resting "idle" pill is controlled by `features.idle_pill`. |
| `lib/diff_bubble.lua` | Card above the pill, in three kinds: the "what changed" word diff with undo (`features.diff_bubble`), the read-only **answer card** for `output: "show"` modes (`features.result_card`), and the **reply card** for `output: "replies"` (`features.reply_helper`). |
| `lib/history.lua` | Local fix history (`data/history.jsonl`) and the mistake tracker: record, prune, undo-marking, and `stats()` (`features.history`). |
| `lib/history_window.lua` | **History & Progress…** window: searchable history with diffs and Copy/Delete, plus the My Progress tab. |
| `lib/word_diff.lua` | Pure-Lua word-level diff: tokenize, trim the common prefix and suffix, run LCS, and group edits. No AI call. |
| `lib/radial_menu.lua` | Hold-and-flick ring of modes at the pointer (`features.radial_menu`). Applies through `text_replacer.run`. |
| `lib/dictation.lua` | Hold-to-talk dictation (`features.dictation`): records with ffmpeg, transcribes with Gemini or local whisper.cpp, optionally polishes the text, and types it at the caret via `text_replacer.insert_text`. |
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
                      ├─ mode.output == "replies" → restore the clipboard, parse JSON (`%b{}`) →
                      │    diff_bubble.show_replies() (malformed JSON → answer card with the raw text). Stop.
                      ├─ mode.output == "show" → restore the clipboard (⌘C path), hud.success,
                      │    diff_bubble.show_text(answer) (or answer → clipboard if the card is off). Stop:
                      │    the selection is never written.
                      ├─ result == original → nothing written, hud.success("No changes needed")
                      ├─ ax_ctx and can_write → ax_text.replace()        (direct, verified)
                      │    ├─ "selection changed while working" → result → clipboard, error, stop
                      │    └─ other failure → paste fallback
                      ├─ paste fallback: clipboard ← result, ⌘V, restore the clipboard
                      ├─ play a sound (defaults.sound)
                      └─ hud.success("Done", time) + history.record(...)
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

## Reply Helper (`output: "replies"`)

- **Mode:** Reply Helper (⌃⌘R). Its prompt asks for JSON only: `{ meaning, replies: [{label, text}] }` with Short / Detailed / Polite no (or Warm), in the message's language, and the meaning always in simple English. `text_replacer` extracts the first balanced `{…}`, decodes it, and hands it to `diff_bubble.show_replies()`. History gets a `show` entry with `Meaning:` / `<label>:` lines.
- **Reply card** (`kind = "replies"`, up to 3 options, body up to 330 px): unlike the other cards it does **not** close on outside clicks, so you can click into your reply box. While it's open, the 0.1 s poll remembers the last focused non-Hammerspoon window (`_session.win`) as the insertion target.
- **Keys:** `1`–`n` with no modifiers insert a reply, but only while `armed`: any other key disarms it and passes through, so digits you type are never swallowed. `esc` closes (and passes through). Clicking an option inserts it, and **Copy** copies it.
- **Insert:** `choose_reply()` closes the card, refocuses the target window if needed, and 120 ms later calls `text_replacer.insert_text()`. That uses `ax_text.insert_at_focus()` (sets `AXSelectedText` at the caret, verified, and skipped for web content unless `web_content: direct`), or otherwise pastes with clipboard restore.
- `features.reply_helper`: `enabled` (off → the answer card shows the raw text), `duration_seconds` (45).

## Fix history & My Progress (`lib/history.lua`, `lib/history_window.lua`)

- **Storage:** `data/history.jsonl` in the install folder, one JSON object per line, appended on every successful fix (`output: "replace"`, only when the text changed) and every show-mode answer (`output: "show"`). `data/` is git-ignored, so history stays on each Mac: a work laptop and a personal laptop each have their own. Nothing is uploaded.
- **Entry:** `{ id, ts, mode, output, app, original, result, tracked?, mistakes?, undone? }`. The app comes from `ax_ctx.app` or the frontmost app when the fix started.
- **Pruning:** on the first load after (re)configure, entries older than `retention_days` (and beyond 5000) are dropped and the file is rewritten.
- **Mistakes:** only for modes in `mistake_modes` (default `["Fix Grammar", "Minimal Fix"]`, so rewrites like Make Concise don't count). At record time the word diff's del/ins groups become `{ from, to, cat }`. `classify()` checks, in order: Capitalization, Apostrophes, Punctuation, Articles (a/an/the), Singular/plural, Verb form (aux verbs), Prepositions, Spelling (edit distance ≤ 2), Rewording (more than 6 words), and otherwise Word choice.
- **Undo:** the diff bubble calls `history.mark_undone(history.last_id())`. Undone entries stay in History (with an "undone" badge) but are excluded from My Progress.
- **`stats()`:** this week vs last week (fixes, mistakes), per-category counts (this week and total), the 12 most repeated `from → to` pairs (excluding Rewording), and an 8-week series.
- **Window:** a normal titled window (menu bar → **History & Progress…**) that is focused on open, because a menu bar app's windows don't come forward on their own. Data is pushed as JSON with `load()`, and the page normalizes lists because empty Lua tables may arrive as `{}`. Entry diffs are computed on demand (`detail`). **Clear all history** needs a second click to confirm.
- `features.history`: `enabled`, `retention_days` (90), `exclude_apps`, `mistake_modes`.

## Show modes & the answer card

- A mode with `output: "show"` (parsed in `config_loader`; the default is `"replace"`) asks the AI a question about the selection instead of rewriting it. The shipped example is **Explain Meaning** (⌃⌘M): a plain-English meaning of the text, including any request, deadline, or tone. It works on read-only text (e.g. someone else's message), since capture is a direct AX read or a ⌘C.
- The answer appears in `diff_bubble.show_text()`, the same window, countdown, and hover-to-hold as the diff, with `kind = "text"`. It shows the mode name, "your text wasn't changed", and the answer (up to 220 px, scrollable), with a **Copy** button instead of Undo. Answer lines of the form `Label: text` (e.g. Explain Meaning's `Meaning:` and `Roman Urdu:`) are rendered as labeled rows by `rows()` in the page. Other lines continue the current row. The prompt decides the rows. Any key press or a click outside dismisses it and passes through. The undo hotkey isn't intercepted.
- `features.result_card` (`enabled`, `duration_seconds`: 15). When disabled, the answer is copied to the clipboard with an info pill.
- Show modes join the picker and the radial menu like any other mode (Explain Meaning is radial slot 6 by config order).

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

## Voice dictation (`lib/dictation.lua`)

> Superseded by the native app (`macos/`, below), which starts recording instantly and keeps a Voice History. `macos/install.sh` sets this feature's `enabled: false`; the Lua module stays for Macs without the native app.

- **Trigger:** hold a right-hand modifier (`trigger`, default `right_control`; also `right_command`, `right_shift`, `right_option`, `fn`). It uses the same persistent `flagsChanged` tap pattern as the radial menu and never swallows modifier events. A session starts **pending** and recording begins only after `hold_ms` (200), so a tap or a chord (another key or modifier while pending) does nothing. `features.normalize` disables dictation if its trigger equals the radial menu's.
- **Record:** `ffmpeg -f avfoundation` (`microphone`, default device) writes 16 kHz mono WAV to `$TMPDIR/flickwise-dictation.wav`, capped at `max_seconds`. `-probesize 32 -analyzeduration 0 -fflags nobuffer` cut startup from ~2.5 s to ~1 s. The pill says **Starting mic…** and switches to **Listening…** at ffmpeg's first progress line (`size=`), i.e. once audio is flowing. Releasing sends SIGINT (`task:interrupt()`), so ffmpeg finalizes the file and its exit callback continues. Esc cancels. Audio shorter than ~0.5 s counts as a stray tap. The WAV is deleted as soon as the transcript is back.
- **Transcribe (step 1, verbatim):** `provider: gemini` sends the audio as `inline_data` to `ai_client.transcribe` (temperature 0). `provider: whisper` runs `whisper-cli -m <whisper_model> -f wav -nt -np -l <language>` (offline).
- **Polish (step 2, text):** `style: clean` (fix fillers and grammar, same language) or `english` (translate Urdu/Hindi/mixed and polish) rewrites the transcript through `ai_client.transform`. `verbatim` skips it. This is a separate text call because Gemini's audio mode keeps "um/uh/like" however it is prompted, while a text rewrite follows the instruction reliably. If it fails, the raw transcript is used.
- **Insert:** `text_replacer.insert_text` (Accessibility, or paste with clipboard restore). `[NO_SPEECH]` or empty text shows "Didn't catch any speech".
- **Needs:** ffmpeg (`brew install ffmpeg`), microphone permission for Hammerspoon, Accessibility, and (for `gemini`) the API key. The `glean` backend can't take audio, so `provider: gemini` needs a Gemini key even when Glean handles fixes.
- **State machine:** `pending → starting → recording → processing`. Every exit goes through `end_session()` or `cancel()`, which stop the timer and key tap and delete the WAV. The exit callback runs under `xpcall` so an error can't leave the session stuck.
- Testing note: posting `hs -c` commands that time out leaves stale CLI sessions that make `print` error ("ipc port is no longer valid"). Use `hs -q`, and restart Hammerspoon if it happens.

## Native app (`macos/`)

A Swift menu bar app (AppKit + SwiftUI, macOS 13.3+, about 1 MB plus the 8.5 MB whisper.cpp framework) that does hold-to-talk dictation, recognizing speech **on the Mac with Whisper** by default, and keeps a searchable **Voice History**. It is the long-term home for every Flickwise feature (IDEAS 5.1); dictation is the first to move.

### Build, sign, install

- **No Xcode and no SwiftPM:** `macos/scripts/build.sh` calls `swiftc` directly on `Sources/**/*.swift` (whole-module optimized, `-lsqlite3`), then assembles `build/Flickwise.app` (Info.plist with `__VERSION__` from `macos/VERSION` and `__BUILD__` = the git commit count, plus an icon made from `assets/flickwise-icon-1024.png`). SwiftPM was dropped because a stale Command Line Tools install can ship a mismatched `PackageDescription`.
- **whisper.cpp:** `build.sh` downloads the official prebuilt `whisper-b5130-xcframework.zip` (whisper.cpp v1.9.4) once into `macos/vendor/` (git-ignored), checks its SHA-256, and takes the `macos-arm64_x86_64/whisper.framework` slice (universal, Metal + Core ML, with a module map so Swift can `import whisper`). It links with `-F vendor/... -framework whisper` and rpath `@executable_path/../Frameworks`, copies the framework into `Contents/Frameworks/`, and signs it before the app. The minimum macOS is 13.3 because of the framework. To upgrade, change `WHISPER_TAG`/`WHISPER_SHA256`.
- **Stale-CLT workaround:** if the toolchain has both `usr/include/swift/module.modulemap` (a 2023 leftover) and `bridging.modulemap`, every import fails with "redefinition of module 'SwiftBridging'". The build hides the stale file with a VFS overlay (`-vfsoverlay` and `-Xcc -ivfsoverlay`), so no sudo is needed.
- **Stable signature:** `scripts/signing-identity.sh` creates (once) a self-signed "Flickwise Local Signing" code-signing certificate in its own keychain (`~/Library/Application Support/Flickwise/signing/`, added to the user search list). Its designated requirement is `identifier "app.flickwise.mac" and certificate leaf = H"…"`, so **TCC grants (Accessibility, Microphone) survive rebuilds**. Ad-hoc signing (the fallback) changes the requirement on every build.
- **Why the API key is not in the Keychain:** without an Apple Team ID, Keychain items are bound to the binary's cdhash, so every rebuild shows a blocking "wants to access key" password prompt (which hung the launch inside `SecItemCopyMatching`). The key lives in `gemini_api_key` (mode 0600) in Application Support instead (`Secrets.swift`).
- `macos/install.sh` (idempotent, non-interactive): checks macOS 13+ and `swiftc`; builds from the checkout it's in, or clones/pulls into `~/Library/Application Support/Flickwise/source` when piped from curl; quits the running copy; installs to `~/Applications/Flickwise.app`; **downloads the speech model** (`FLICKWISE_MODEL`, default `large-v3-turbo-q8_0`; the URL, checksum and path come from `Flickwise --model-info`, so the catalog lives only in Swift; `curl -C -` resumes, then `shasum` verifies, then the `.part` file is renamed; skipped if present; `FLICKWISE_SKIP_MODEL=1` skips it) and, with `FLICKWISE_NEURAL_ENGINE=1`, the Core ML encoder (`--coreml-info`, unzipped with `ditto`) (replacing the Hammerspoon Spotlight launcher, which `install.sh` then no longer recreates); flips `features.dictation.enabled` to false in `~/.hammerspoon/flickwise/config.yaml` (backup first, `FLICKWISE_KEEP_HS_DICTATION=1` to skip); opens the app. Overrides: `FLICKWISE_REPO`, `FLICKWISE_BRANCH`, `FLICKWISE_SRC`, `FLICKWISE_APPS_DIR`, `FLICKWISE_HS_DIR`, `FLICKWISE_NO_LAUNCH`.

### Module map (`macos/Sources/Flickwise/`)

| File | Role |
|---|---|
| `App/main.swift` | Entry point. `--selftest`, `--transcribe <wav>`, `--benchmark …`, `--load-test`, `--gate`, `--diff <cases.json>`, `--import-preview`, `--model-info`, `--coreml-info`, `--render <page> <png>` run headless (`App/SelfTest.swift`, `App/Benchmark.swift`) and free the Whisper model before exiting; otherwise starts NSApplication (main-actor) as an accessory (menu bar) app. |
| `App/AppDelegate.swift` | Wires settings → `DictationController`, builds the status item menu (rebuilt on open: status line, words today, Voice History, Style submenu, Pause, Settings, Set Up), opens Setup when a permission or the recognizer is missing, **otherwise opens Voice History when launched by hand** (not when launched as a login item: `keyAELaunchedAsLogInItem`), handles **reopen** (opening the app again while it runs shows Voice History), polls for Accessibility, prunes history. `menuBarIconHidden` is true when macOS has put the status item behind the camera notch (its window lies outside the screen's `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), which happens when the menu bar is full; Voice History then shows a tip. Single-instance. `FLICKWISE_OPEN=history|settings|hud` opens a window (or plays a HUD demo) at launch for testing. |
| `App/MainMenu.swift` | The app menu shown while a window is open (About, Settings… ⌘,, Set Up, Hide, Quit; Edit with Cut/Copy/Paste/Select All, which text fields need for ⌘V; Window). |
| `App/WindowManager.swift` | Opens the main window (`"main"`, `MainWindowView`) and Setup as normal windows hosting SwiftUI, with `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]` so they appear on the current Space even over a full-screen app (otherwise they open on a desktop Space and seem not to open). While any is open the app is `.regular` (Dock and ⌘-Tab); when the last closes it goes back to `.accessory`. |
| `App/Permissions.swift` | Accessibility (`AXIsProcessTrustedWithOptions`), Microphone (`AVCaptureDevice`), System Settings deep links, and the login item (`SMAppService.mainApp`). |
| `Input/HotkeyMonitor.swift` | A persistent `CGEventTap` on `flagsChanged` reports press/release of the trigger. It tells left from right by the device-dependent flag bit and never swallows modifiers. A second tap on `keyDown`, live only during a session, reports chords and swallows **Esc**. Taps disabled by timeout are re-enabled. |
| `Input/TriggerKey.swift` | Right ⌘ / ⌥ / ⌃ / ⇧ and Fn: keycodes, device masks, labels. |
| `Audio/AudioRecorder.swift` | `AVAudioEngine` input tap → `AVAudioConverter` → 16 kHz mono Int16 PCM in memory (no temp file). Optional input device by CoreAudio UID. Reports a smoothed 0…1 level for the waveform. `WAV.encode` adds the 44-byte header. `AudioDevices` lists inputs. |
| `Transcription/WhisperModel.swift` | The model catalog (id, size, SHA-256, `translates`, optional Core ML `Asset`) for `huggingface.co/ggerganov/whisper.cpp`, and `ModelStore`, which downloads with URLSession (progress published in 0.5% steps), verifies SHA-256 by streaming, renames `.part` into `models/`, and deletes models. Core ML encoders arrive as `<name>-encoder.mlmodelc.zip`; they are verified, unpacked with `ditto`, and placed beside the model (whisper.cpp finds them by name: the model id without its `-qN_M` suffix). Posts `ModelStore.didInstall`. |
| `Transcription/WhisperEngine.swift` | whisper.cpp in process, on one serial queue. `preload` (load once and keep), `transcribe(pcm:model:language:translate:)` (greedy, no timestamps, no context, `suppress_nst`, flash attention, GPU), `isReady` (lock-protected, so the main thread never waits on a load), `unload`, and `shutdown()`, which **must** run before exit (ggml's Metal backend asserts at `exit()` if a context still holds buffers). whisper.cpp logs are routed to our log (errors only, minus "failed to load Core ML model"). |
| `Transcription/Transcriber.swift` | Recording → `Transcript{raw, text, engine}`. The **speech gate** comes first: `Speech.trimmedToSpeech` (30 ms RMS frames; threshold = max(0.005, min(3× the 10th-percentile floor, 30% of the loudest frame)); at least 6 voiced frames; 300 ms padding) returns nil on silence. The cap at 30% of the peak matters: a short clip with no pauses ("Hello there.") has no real noise floor, and the first version (3× the 20th percentile) rejected every short dictation. Rejections log their levels (numbers only); `Flickwise --gate files…` prints the same numbers at several mic gains, for both engines (Whisper and Gemini both invent text from silence). Local: Whisper (translate only for style `english` with a model that `translates`), then `Speech.dropHallucination` and `Speech.cleanFillers` for non-verbatim styles. Gemini: cloud transcription. Gemini polish runs when the engine is Gemini, or with `polish_with_gemini` and a key. |
| `AI/GeminiClient.swift` | `transcribe(wav:)` (inline audio, temperature 0) and `rewrite(text:instructions:)` over URLSession async, typed errors (`GeminiError`), the same post-processing as `ai_client.lua`, and `warmUp()` (a HEAD request that opens the TLS connection). `Prompts` holds the same transcribe/polish prompts as `lib/dictation.lua`. |
| `Dictation/DictationController.swift` | The state machine, the processing pipeline, and Retry (below). |
| `Output/TextInserter.swift` | Port of `ax_text.insert_at_focus` + paste. It sets `AXSelectedText` on the focused element and verifies it, except for secure fields and web content (an `AXWebArea` ancestor or DOM attributes), which get a paste. Paste saves every pasteboard item, writes the text marked `org.nspasteboard.TransientType`, posts ⌘V, and restores after 350 ms unless the clipboard changed meanwhile. With no focused element the text is copied instead. AX messaging timeout is 1 s. |
| `History/HistoryStore.swift` | SQLite (WAL) `dictations` table plus an FTS5 external-content index (`text`, `raw_text`, `app_name`, kept in sync by triggers), on a serial queue. Search turns input into quoted prefix terms (`"meet"*`). `stats()`: today/week/total words, speaking time, day streak, and minutes saved vs typing at 40 wpm. `prune(olderThanDays:)` also removes audio. `revision` is published so windows refresh. |
| `Settings/AppSettings.swift`, `SettingsStore.swift` | Codable settings with tolerant decoding (missing keys keep defaults, values clamped), saved as snake_case `settings.json` on every change and published to observers. |
| `Settings/LegacyImport.swift` | Imports the Hammerspoon setup with `MiniYAML`: on first launch everything (dictation, Gemini model/Glean path → `ai.backend`, picker hotkey, sound, diff/answer/reply cards, radial menu, direct replace, history excludes and mistake modes); `modes()` for `ModeStore`; `migrateIfNeeded` once per Mac for installs that predate the fixes (fix settings + `data/history.jsonl` → history DB), marked by `.imported-hammerspoon-v2`; `importAPIKeyIfMissing` on every launch. Radial modes come in as names (`radial_menu.mode_names`) and are matched to mode ids after `ModeStore` loads. `--import-preview` prints what would be imported. |
| `Settings/Secrets.swift` | The API key file (0600). |
| `UI/NotchHUD.swift` | The default indicator (`dictation.indicator: "notch"`): a black island that springs out of the MacBook notch. It's a borderless, non-activating `TopPanel` (760×200, above the menu bar at `mainMenu + 2`, ignores the mouse, all Spaces, and won't be pushed below the menu bar). It starts at the notch's exact size (from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` widths and `safeAreaInsets.top`), then a spring expands `NotchShape` (concave "ears" where it meets the menu bar, rounded bottom). Listening: wings beside the camera with **Flicky** (the mascot: a violet→cyan orb with blinking eyes; it pulses with the voice level, looks around while thinking, ^ ^ when done, worried on error) on the left, and a gradient waveform plus timer on the right, with a glow line along the bottom that breathes with the level. Working/done/info/error: a status row under the notch. Auto-hide shrinks it back into the notch, then orders the panel out. On screens without a notch, the same island grows down from the top centre (virtual notch 150×0). |
| `UI/HUD.swift` | The facade every caller uses: forwards to `NotchHUD` when `indicator` is `notch`, otherwise shows the bottom-center pill: a borderless, non-activating `NSPanel` (`.statusBar` level, ignores the mouse, all Spaces) hosting SwiftUI. States: Listening (pulsing dot, 26-bar live waveform, timer, "esc to cancel"), working (spinner), done (with a preview), info, and error, with auto-hide. |
| `UI/HistoryView.swift` | History: stat tiles (dictation words), full-text search as you type (debounced 120 ms), a filter (All / Dictation / Fixes & answers), entries grouped by day with time and app. Dictations show style, engine, words and duration; fixes and answers show the mode, the number of mistakes, and "undone". On hover: Copy, Original / What changed (a fix shows its word diff), Retry (failed dictations), Delete. Export as Markdown. A tip when the menu bar icon is hidden by the notch. |
| `Modes/Mode.swift` | `Mode` {id, name, hotkey, output replace/show/replies, temperature?, showDiff, enabled, timeoutSeconds?, prompt} with tolerant decoding, and `KeyCombo` (key code + ⌘⇧⌥⌃), stored as names like `["cmd","shift","g"]` (the Hammerspoon format), with symbols for display, Carbon modifiers, and `matches(CGEvent)`. |
| `Modes/ModeStore.swift` | The ordered modes in `modes.json` (Application Support), published; add / duplicate / delete / move / update, conflict check, restore defaults. A fresh install starts from the Hammerspoon config's modes (`LegacyImport.modes()`), else `DefaultModes`. Order = menu, picker numbers and radial slots. |
| `Modes/DefaultModes.swift` | The 7 shipped modes, generated from `config.example.yaml` so the prompts match word for word. |
| `Input/GlobalHotkeys.swift` | Carbon `RegisterEventHotKey` for every enabled mode's shortcut and the picker (no Accessibility needed; the key press is consumed). Re-registered when modes or picker settings change, and paused while a shortcut is being recorded. Combos owned by another app are logged. |
| `Input/EventTap.swift` | A short-lived CGEventTap for a popup's session (card, picker, radial ring); the handler returns true to swallow. Re-enables itself after a timeout. |
| `Fixes/FixController.swift` | Port of `text_replacer.lua`: capture (Accessibility, else ⌘C) → HUD working → `TextBackend` → by output: replace (direct write + verify, or paste with the clipboard restored; refuses if the selection changed meanwhile), sound, history (+ mistakes for `mistake_modes`), "what changed" card with Undo; show → answer card (or clipboard); replies → `ReplyData` (first balanced `{…}`) → reply card. Undo: Accessibility restore for direct writes, else ⌘Z (`app`) or shift+← × n and paste (`reselect`). One run at a time. `insert(_:into:)` types a chosen reply at the caret. |
| `Fixes/Selection.swift` | Port of `ax_text.lua`: `readDirect` (AXSelectedText + range, writable, web-content detection, excluded apps), `canWrite`, `replace` (reselects the captured range and checks it still holds the text), `restore` (undo), and `captureByCopy` (⌘C, waits up to 2 s for the clipboard to change; keeps the old clipboard to restore). |
| `Fixes/TextBackend.swift` | Runs a mode on text: Gemini (`GeminiClient.rewrite`, the mode's temperature) or the **Glean CLI** (`glean chat --json`, agent FAST, `saveChat: false`; output streamed so a full pipe can't block; auth errors → "run: glean auth login"; timeout). |
| `Fixes/WordDiff.swift` | Port of `word_diff.lua` (tokenize, prefix/suffix trim, LCS ≤ 250k cells, grouping) and of the mistake classifier from `history.lua` (Capitalization … Word choice). Verified identical to the Lua output with `--diff`. `collapsed(_:context:)` shortens long unchanged stretches. |
| `Fixes/ProgressStats.swift` | My Progress numbers (port of `history.lua` `stats()`): this week vs last, categories, top 12 repeated corrections (no Rewording), 8 weeks. |
| `UI/ResultCard.swift` | Port of `diff_bubble.lua`: one non-activating panel, three kinds (diff with Undo, answer rows "Label: text" with Copy, replies 1–n with Copy), under the notch island (or above the bottom pill), countdown bar that pauses on hover. Session tap: undo shortcut (only while the fixed app is frontmost), digits from the typed character (top row or keypad) while armed; other keys dismiss diff/answer cards and pass through, or disarm the reply card; outside clicks close diff/answer cards. `DiffText` renders a diff as one `Text`. |
| `UI/ModePicker.swift` | Port of `mode_picker.lua`: ⌘⇧P (configurable) captures the selection, then a palette under the notch: type to filter, ↑/↓, Return, 1–9, Esc; clicks run a row. Keys come from a session tap, so focus never leaves your app. |
| `UI/RadialMenu.swift` | Port of `radial_menu.lua`: a `HotkeyMonitor` on the trigger (Right ⌥) → pending → after `hold_ms` a ring of up to 8 modes at the pointer (flattened ellipse, slot 1 on top, clockwise, spring-out stagger). Pointer direction outside a 28 pt dead zone highlights; release / left click applies, 1–8 apply, right click / Esc cancel, other keys cancel and pass through. Off when its trigger equals the dictation key. |
| `UI/ModesView.swift` | The Modes page: reorderable list (drag), add / duplicate / delete / restore defaults; the editor (name, enabled, `HotkeyRecorder` with conflict warnings, output, "what changed" toggle, temperature, the prompt) and **Try it**, which runs the prompt on sample text with the real backend. |
| `UI/MainWindow.swift` | The app window: sidebar History, My Progress, Modes, Dictation, Features, AI, General (`MainNav.page`). |
| `UI/ProgressView.swift` | `MyProgressView`: weekly tiles with deltas, 8-week bars, mistakes by type, most repeated corrections. |
| `Settings/MiniYAML.swift` | Reads the YAML subset of the Hammerspoon config (nested maps, lists of maps, flow lists, `|` block scalars, comments) for the import. |
| `UI/SpeechViews.swift` | `ModelRow` (status, Download with progress, Use, Delete, and a "Neural Engine boost" line) and `SpeechSection` (engine, models, language, keep loaded, Gemini polish, plus a note explaining privacy and translation limits). Used by Settings and Setup. |
| `UI/SettingsView.swift` | The settings pages of the main window: `DictationPane` (speech recognition + dictation + indicator), `FeaturesPane` (text fixes: direct replace, web content, excluded apps, sound; the "what changed" card with undo shortcut and method; answer and reply cards; picker; radial menu), `AIPane` (backend Gemini/Glean, Glean path + Test, Gemini key + model, timeout), `GeneralPane` (history, retention, excluded apps, mistake modes, delete all, open at login, debug). `ListField` edits short string lists. |
| `UI/SetupView.swift` | The first-run checklist (rechecked every second): Accessibility, Microphone, Speech recognition (download the model, or switch to Gemini and enter a key), open at login, and a "Try it here" text box. |
| `Support/Paths.swift`, `Log.swift` | Folders (`FLICKWISE_SUPPORT_DIR` overrides Application Support for tests) and the file log (trimmed to 1 MB once it passes 2 MB, POSIX timestamps, transcripts only with `debug`). |

### Dictation flow

```
Right ⌘ down (no other modifier) ─► pending
   ├─ instant_start + mic authorized → engine starts now (audio queue)      ← first word never clipped
   ├─ engine gemini → GeminiClient.warmUp()                                  ← TLS while you speak
   ├─ other key / modifier (chord) or release before hold_ms → discard audio, back to idle (silent)
   └─ hold_ms passes → recording: HUD Listening + waveform, "Pop", max_seconds timer,
        prepareEngine(): load the Whisper model if it isn't loaded              ← ~0.6 s while you speak
        ├─ Esc → discard, "Cancelled"
        └─ release (or max_seconds) → processing: engine stops → WAV in memory
             ├─ < 0.5 s → "Too short"
             ├─ speech gate: no speech → "Didn't catch any speech" (nothing is sent anywhere)
             ├─ local: Whisper (model kept loaded; "Loading speech model…" if it isn't ready yet)
             │    → drop hallucinations → clean fillers (styles clean/english)
             ├─ gemini: transcribe (verbatim) → "[NO_SPEECH]"/empty → "Didn't catch any speech"
             ├─ Gemini rewrite if engine=gemini or polish_with_gemini (falls back to the transcript on error)
             ├─ TextInserter.insert → HUD "Inserted"/"Copied" + "Tink"
             ├─ history.add({text, raw, app (frontmost at key-down), style, duration, status, engine})
             └─ any recognizer error → audio saved to audio/<uuid>.wav, entry status "failed", HUD says Retry is in History
```

- Event-tap callbacks only enqueue work on the main queue (nothing slow runs inside a tap). The audio engine starts and stops on a serial `userInteractive` queue. A `session` counter makes stale timers and callbacks no-ops.
- **Retry** (History → Retry) re-runs the saved audio with the entry's style, copies the result to the clipboard (focus is on the History window, not where you were typing), updates the entry, and deletes the audio unless `keep_audio`.
- One dictation at a time: pressing while processing shows "Still working on the last one…".
- **Model memory (`keep_model_loaded`, default false = on demand):** the model is loaded when a hold becomes a recording (after `hold_ms`, not on key-down, so Right ⌘ shortcuts never load it). The ~0.6 s load overlaps with your speech, and the model is freed after the dictation, a cancel, or a Retry (`releaseModelIfIdle`). At launch, after a download, and on setting changes, `prepareSpeechModel` runs `WhisperEngine.warmUp` (load + free), so one-time setup after an install or update (~20 s of GPU/Neural Engine compile) never lands on a dictation. With `keep_model_loaded: true` the model is preloaded and kept (~1 GB). It's always unloaded when the engine is Gemini.
- Measured with `Flickwise --load-test` (turbo q8 + Neural Engine, 6.4 s clip): reload 0.50–0.75 s, recognize ~1.4 s, so ~2.0 s if nothing overlapped. In practice the load runs while you talk, so release → text stays ~1.4 s. Memory is ~980 MB loaded and 40–220 MB after unloading (the allocator returns memory lazily; no growth over 10 cycles). The first load in a new process is ~1.3 s.
- History's `engine` column (added by a migration in `HistoryStore.open`, `PRAGMA table_info` then `ALTER TABLE`) records `whisper:<model>` or `gemini:<model>`. It's shown as a tag on each entry.

### Text fixes (the app)

```
mode shortcut (Carbon) / menu bar Modes / picker row / radial slot
   └─ FixController.run(mode)          (picker & radial pass the selection they captured)
        ├─ ResultCard.dismiss()
        ├─ capture: Selection.readDirect (AX)  →  else captureByCopy (⌘C, old clipboard kept)  →  else "Select some text first"
        ├─ HUD.working(mode name)   (notch island: Flicky thinking)
        ├─ TextBackend: Gemini (mode temperature)  |  Glean CLI (Fast agent, chat not saved)
        └─ output
             ├─ replies → restore clipboard → ReplyData.parse → reply card (1–n inserts at the caret) | answer card | clipboard
             ├─ show    → restore clipboard → answer card ("Label: text" rows) | clipboard
             └─ replace → unchanged? "No changes needed"
                          → direct write (AX, verified; web content pastes unless web_content = direct)
                            · "selection changed while working" → result to the clipboard, error, stop
                          → else paste + restore the clipboard
                          → sound, HUD "Done 0.8 s", history {kind fix, mode, original, result, mistakes?}
                          → "what changed" card (unless the mode or setting turns it off) → Undo marks the entry undone
```

Measured end to end in TextEdit (Gemini flash-lite): Fix Grammar 0.7–1.2 s from shortcut to replaced text; Explain Meaning 1.2 s; Reply Helper 1.0 s.

### Migrating from Hammerspoon

- `macos/install.sh` (step 6b) comments out `require("flickwise")` in `~/.hammerspoon/init.lua` (backup `init.lua.backup.<ts>`) and reloads Hammerspoon, so its hotkeys, radial tap and menu bar item are released before the app registers its own (Carbon refuses combos another app holds). `FLICKWISE_KEEP_HAMMERSPOON=1` skips it. To go back: remove the `-- ` and quit the app.
- On first launch the app imports modes (`modes.json` absent), settings (first launch) or fix settings + fix history (`migrateIfNeeded`, once), so nothing has to be re-entered. The Hammerspoon files are only read, never changed by the app.
- The Lua `install.sh` recognises the native app (`app.flickwise.mac` in `~/Applications`) and doesn't add `require("flickwise")` back.
- Not ported: the resting "idle pill" (the notch island replaces it) and the radial menu's `caret` anchor and chord triggers (modifier triggers only).

### Speech recognition: measurements (M1 Pro, 16 GB, macOS 26)

Same clips through each recognizer (`Flickwise --benchmark`, synthetic `say` voices: 6 s English with fillers, 20 s English, 6 s Hindi, 2 s silence), seconds from audio to text with the model already loaded:

| Recognizer | Size | 6 s / 20 s / Hindi | Notes |
|---|---|---|---|
| Whisper large-v3-turbo q8_0 **+ Neural Engine encoder** | 874 MB + 1.2 GB | **1.31 / 1.45 / 1.49** | Fastest turbo. First load compiles the encoder (~130 s, once); later loads take ~2 s |
| Whisper large-v3-turbo q8_0 (default) | 874 MB | 1.76 / 1.92 / 1.94 | Same text as full and q5 |
| Whisper large-v3-turbo (f16) | 1.6 GB | 1.67 / 1.85 / 1.87 | |
| Whisper large-v3-turbo q5_0 | 574 MB | 2.00 / 2.14 / 2.16 | Smaller but slower on Metal |
| Whisper small | 488 MB | 0.43 / 0.68 / 0.50 | Same English; dropped half of the Hindi sentence. The Core ML encoder gave no gain |
| Whisper base | 148 MB | 0.17 / 0.29 / 0.80 | Small English slips; Hindi came out in Urdu script |
| Gemini flash-lite (cloud) | — | 2.72 / 2.76 / 1.74 | + ~0.7 s for the polish call; network-dependent, rate-limited; **invented a sentence from silence** |

- Turbo's time barely depends on clip length: the encoder always processes a 30 s window. Shrinking it (`audio_ctx`) made turbo produce garbage on short clips, so it isn't used. Flash attention is 25% faster than without.
- First Metal use after installing compiles GPU shaders (~20 s, once; macOS caches them).
- Turbo keeps fillers ("Um, so, … like"), which `Speech.cleanFillers` removes for Clean up / Polished English. Turbo does **not** translate (it was trained without translation data), so Polished English from Urdu/Hindi speech needs Small (`translate`) or Gemini polish.
- Memory: about 1 GB resident with turbo q8 loaded, which is why loading on demand is the default.

### Settings (`settings.json`)

```json
{
  "dictation": { "enabled": true, "trigger": "right_command", "hold_ms": 200, "instant_start": true,
                 "style": "clean", "max_seconds": 300, "microphone": "", "sounds": true, "indicator": "notch" },
  "transcription": { "engine": "local", "model": "large-v3-turbo-q8_0", "language": "auto",
                     "polish_with_gemini": false, "keep_model_loaded": false },
  "history":   { "enabled": true, "retention_days": 0, "keep_audio": false, "exclude_apps": [],
                 "mistake_modes": ["Fix Grammar", "Minimal Fix"] },
  "ai":        { "backend": "gemini", "model": "gemini-flash-lite-latest", "timeout_seconds": 60, "glean_path": "" },
  "fixes":     { "direct_replace": true, "web_content": "paste", "exclude_apps": [], "sound": "Tink" },
  "diff_card": { "enabled": true, "duration_seconds": 6, "undo_hotkey": ["cmd", "z"], "undo_method": "app", "context_words": 8 },
  "result_card": { "enabled": true, "duration_seconds": 15 },
  "reply_card":  { "enabled": true, "duration_seconds": 45 },
  "picker":      { "enabled": true, "hotkey": ["shift", "cmd", "p"] },
  "radial_menu": { "enabled": true, "trigger": "right_option", "hold_ms": 150, "modes": [] },
  "debug": false
}
```

`ai.backend`: `gemini | glean` (text fixes). `undo_method`: `app | reselect`. `radial_menu.modes`: mode ids clockwise from the top (empty = the first 8 enabled modes). Modes themselves live in `modes.json` (an ordered array of `Mode`). `indicator`: `notch` (island from the notch; top centre on screens without one) or `pill` (bottom capsule). `engine`: `local | gemini`. `model`: a `WhisperModel.catalog` id (`large-v3-turbo-q8_0`, `large-v3-turbo-q5_0`, `large-v3-turbo`, `small`, `base`); unknown ids fall back to the default. `language`: `auto` or a Whisper code (`en`, `ur`, `hi`, …). `trigger`: `right_command | right_option | right_control | right_shift | fn`. `style`: `verbatim | clean | english`. `microphone`: a CoreAudio device UID, or `""` for the system default. `retention_days: 0` keeps everything. Every feature has its `enabled` flag here (the native counterpart of `features:` in `config.yaml`).

### Testing

- `FLICKWISE_SUPPORT_DIR=$(mktemp -d) …/Flickwise --selftest`: text helpers, WAV, settings decoding, and history (insert, FTS search over text/raw/app, update re-indexing, delete, prune, stats, streak).
- `…/Flickwise --transcribe file.wav`: the real pipeline with the current settings (any audio format; it's converted to 16 kHz mono). Make test audio with `say -o t.wav --data-format=LEI16@16000 "…"` (`-v Lekha` for Hindi).
- `…/Flickwise --benchmark [--models a,b] [--gemini] [--language xx] [--translate] files…`: load time and per-clip time and text for each downloaded model (and Gemini). **Don't rebuild while a benchmark runs**: the build replaces the running binary.
- `…/Flickwise --diff cases.json` prints the word diff + mistake categories as JSON for `[[before, after], …]`; the same cases through `lib/word_diff.lua` + `history.classify` (via `hs -c`) must match exactly.
- `…/Flickwise --import-preview` shows what would be imported from the Hammerspoon config (read-only).
- Live fixes: a scratch TextEdit document (`osascript … make new document`), select all, press the mode's shortcut with System Events, read the text back, then delete the test entries from `history.sqlite` (`app_name = 'TextEdit'` after the test's start time). System Events types digits as **keypad** keys, which is why the card reads digits from the event's characters.
- `…/Flickwise --load-test file.wav` (`RUNS=n`): load → recognize → unload cycles with timings and resident memory, which is what `keep_model_loaded: false` costs.
- `…/Flickwise --render main|history|progress|modes|dictation|features|ai|general|setup out.png` (with a sandbox `FLICKWISE_SUPPORT_DIR`; `FLICKWISE_RENDER_IMPORT=1` fills it with the Hammerspoon fix history). The sidebar window and lazy lists don't draw offscreen: check those in the running app.: draws a window's view offscreen (dark mode) to check UI without depending on the active Space.
- UI: `FLICKWISE_OPEN=history|settings|hud FLICKWISE_SUPPORT_DIR=<sandbox> …/Flickwise &`, then snapshot it with Hammerspoon (`hs.application.get("app.flickwise.mac"):allWindows()[1]:snapshot()`).
- The key monitor and insertion need Accessibility, which is granted per signing identity, so test those by hand after a build.

## Config shape

`config.yaml` → `config_loader.load` returns:

```lua
{
  use_glean, glean_binary_path, gemini_api_key, gemini_model, has_api_key,
  defaults = { timeout_seconds, debug, sound },
  debug, picker_hotkey,
  modes = { { name, hotkey, system_prompt, timeout_seconds, diff_bubble, output ("replace" | "show"),
              temperature (0–2 or nil → ai_client default 0.2; Gemini only) } },
  features = {                     -- from features.normalize(), always fully populated
    idle_pill   = { enabled },
    diff_bubble = { enabled, duration_seconds, undo_hotkey, undo_method, context_words },
    radial_menu = { enabled, trigger (string | chord list), hold_ms, anchor, modes },
    dictation   = { enabled, trigger, hold_ms, provider ("gemini" | "whisper"), style ("verbatim" | "clean" | "english"),
                    max_seconds, microphone, language, whisper_model, whisper_bin, ffmpeg_path },
    direct_replace = { enabled, web_content ("paste" | "direct"), exclude_apps },
    result_card    = { enabled, duration_seconds },
    reply_helper   = { enabled, duration_seconds },
    history        = { enabled, retention_days, exclude_apps, mistake_modes },
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
- `data/history.jsonl` is the local fix history (git-ignored, per Mac).
- Native app: `~/Library/Application Support/Flickwise/` (`settings.json`, `modes.json`, `gemini_api_key`, `history.sqlite` (dictations, fixes and answers), `audio/`, `models/`, `.imported-hammerspoon-v2` (Whisper `.bin` files and `*-encoder.mlmodelc`), `signing/`, and `source/` for curl installs) and `~/Library/Logs/Flickwise/flickwise.log`. `macos/build/` and `macos/vendor/` are git-ignored.
- `IDEAS.md` is the roadmap. Tick items and move them to **Done** when they ship.
