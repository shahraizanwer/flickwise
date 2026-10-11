# Flickwise: instructions for Claude

Flickwise is a Hammerspoon (Lua 5.4) tool: select text in any macOS app, press a
hotkey, and the text is replaced with an AI-transformed version. Start with
`ARCHITECTURE.md` for the module map and data flow, and see `IDEAS.md` for the roadmap.

**Flickwise is now one native Swift menu bar app in `macos/`** (IDEAS 5.1): dictation, every mode
(fixes, answers, replies), the cards, picker, radial menu, history and My Progress, all configurable
in its window. The Lua/Hammerspoon code is the previous version: keep it working, but put new
features in the native app.

## Setting up (or updating) Flickwise on another Mac

When asked to install or update Flickwise on a Mac, do this (both steps are idempotent and safe to re-run):

1. **Get the code.** If `~/.hammerspoon/flickwise` exists (the Hammerspoon version, a git clone), update it:
   `git -C ~/.hammerspoon/flickwise pull --ff-only` (if it has local changes, stash them first). Otherwise clone:
   `git clone https://github.com/shahraizanwer/flickwise.git ~/Developer/flickwise`. Hammerspoon isn't needed anymore.
2. **Install the app:** `FLICKWISE_NEURAL_ENGINE=1 bash <repo>/macos/install.sh`.
   It needs only the Xcode Command Line Tools (if `swiftc` is missing it starts their install: finish it, then re-run).
   It builds the app, installs `~/Applications/Flickwise.app`, downloads the on-device speech model (~870 MB) and the
   Neural Engine encoder (~1.2 GB), switches Flickwise off in Hammerspoon (comments out `require("flickwise")` in
   `~/.hammerspoon/init.lua`, backed up), and opens the app. On first launch the app imports the Hammerspoon
   `config.yaml` (modes and prompts, hotkeys, Glean path, settings) and the fix history. Allow 10–20 minutes on a
   slow connection; run it in the background and check its output.
3. **Tell the user what only they can do:** in the setup window that opens, click *Grant Access* (Accessibility) and
   *Allow* (Microphone), then hold **Right ⌘**, speak, and let go. No API key is needed: speech is recognized on the Mac.
   The first launch spends ~2 minutes preparing the Neural Engine encoder, once (in the background).
4. **Check it worked:** `tail ~/Library/Logs/Flickwise/flickwise.log` should show `Modes: started with N (imported…)`,
   `Registered N hotkeys` (and no "Hotkeys taken by another app"), `Radial menu ready`, `Accessibility: true,
   microphone: 3, engine: local, ready: true`. `Flickwise --import-preview` (inside the app bundle) shows what the
   Hammerspoon config contained. `macos/README.md` has troubleshooting details.

On a work Mac that uses the Glean CLI for text fixes, the import sets AI › backend to Glean with the same path
(check: AI page, *Test Glean*). Dictation runs on-device and doesn't use Glean or Gemini.

## Rules

1. **Keep `ARCHITECTURE.md` updated.** Whenever you implement something new or
   change existing behavior (modules, flow, config keys, UI surfaces, key
   handling), update `ARCHITECTURE.md` in the same change, including its
   "Last updated" line. A change isn't done until the doc matches the code.
2. **Every feature must be configurable.** Each optional feature gets an
   `enabled` flag (plus any tunables) under `features:` in `config.yaml`, so it can be
   switched on or off without code changes:
   - defaults go in `lib/features.lua` (`DEFAULTS`, plus a `MENU` entry so it can be toggled from the menu bar)
   - document the block in **both** `config.yaml` and `config.example.yaml`
   - the module exposes `configure(settings)`, called from `apply_config()` in `init.lua`
   - use per-mode opt-outs (e.g. `diff_bubble: false`) where a feature doesn't suit every mode
   - don't keep feature state in `hs.settings` or anywhere else outside `config.yaml`
3. **Keep `features:` above `modes:` in the YAML files.** The prompt editor appends new
   modes at the end of the file.
4. **Update `IDEAS.md`** when an idea ships: tick it, add it to **Done**, and add a
   dated line to the decisions log.
5. **Never touch `gemini_api_key`** in `config.yaml` (it's the user's secret), and
   don't copy it into docs, logs, or commits. `config.yaml` is git-ignored. Shared
   defaults go in `config.example.yaml`, which must always have `gemini_api_key: ""`.
6. **This repo is public** (github.com/shahraizanwer/flickwise). Keep it free of secrets
   and of company-internal names or details. User data lives in git-ignored places only:
   `config.yaml`, `data/` (fix history), and `*.log`. Never commit them, and when testing,
   clear any test entries you add to the real history (`history.clear()` or delete them).
7. **Keep `install.sh` working and idempotent.** It's the only supported install and update
   path (`curl … | bash`). If a change needs a migration (renamed files, new required
   config, a changed `init.lua` hook), add it to `install.sh` so re-running the
   installer upgrades existing machines without overwriting `config.yaml`.

## Conventions

- Match the existing module style: a header comment listing the public API, then `local M = {}`,
  private helpers, a `-- ── public API ──` section, and `return M`.
- Popups are non-activating `hs.webview`s with inline HTML/CSS/JS and the dark look
  used by `hud.lua`, `mode_picker.lua` and `diff_bubble.lua`. Keyboard input comes from an `hs.eventtap`
  that is active only while the popup is visible. Stop the tap before sending synthetic keys.
- A hidden webview never fires `requestAnimationFrame`, so measure and post sizes synchronously.
- Wrap eventtap callbacks in `xpcall`. A Lua error inside a tap must not leave the keyboard stuck.
- Accessibility: the system-wide element is `hs.axuielement.systemWideElement()` (there is no
  `systemElement`). AX text ranges are UTF-16 units (`ax_text.u16len`). Walking a browser's AX tree
  can take many seconds, so never search it broadly.
- Keep a reference to every `hs.timer` you create (including in test stubs). Unreferenced timers
  can be garbage-collected before they fire, which can leave `_in_flight` stuck until a reload.
- Log with `notifier.log` (or `notifier.debug` for verbose output) to `flickwise.log`.

## Testing

There is no standalone `lua` binary. Run code inside Hammerspoon with the `hs` CLI,
and always wrap it in a timeout, because `hs` can hang while Hammerspoon reloads:

```bash
perl -e 'alarm 15; exec @ARGV' hs -c 'return hs.inspect(require("flickwise.lib.word_diff").diff("a ton b", "a to b"))'
perl -e 'alarm 4; exec @ARGV' hs -c 'hs.reload()'   # reload after edits (a port error during reload is normal)
```

- Clear `package.loaded["flickwise.lib.<mod>"]` to reload a single module without a full reload.
- `hs.timer.usleep` blocks Hammerspoon's main thread (webviews won't load or render
  meanwhile), so do follow-up checks in a separate `hs -c` call.
- `screencapture` isn't permitted from the terminal. Use
  `hs.screen.mainScreen():snapshot(rect):saveToFile(path)` from `hs -c` to see UI.
- Test config writers on a scratch copy of `config.yaml`, never the real file.
- To test key and mouse triggers, post synthetic events (e.g. `hs.eventtap.event.newKeyEvent(hs.keycodes.map.rightalt, true):post()`,
  and `newMouseEvent(types.mouseMoved, pt)`), and stub `text_replacer.run` so nothing is copied or sent to the AI.
  Reload afterwards to drop the stubs. Use harmless keys (like F13) so nothing gets typed into the focused app.
- Check `flickwise.log` and the Hammerspoon console for errors after reloading.
- Test the installer in a sandbox, never against the real `~/.hammerspoon`:
  `FLICKWISE_HS_DIR=<tmp>/hs FLICKWISE_APPS_DIR=<tmp>/apps FLICKWISE_REPO=<local clone or URL> FLICKWISE_SKIP_HAMMERSPOON=1 bash install.sh`

## Native app (`macos/`)

- Swift 5 language mode, AppKit + SwiftUI, macOS 13+. `ObservableObject`/`@Published` (no `@Observable`
  or SwiftData, to keep macros out of the build). No third-party dependencies; SQLite through `import SQLite3`.
- Build with `macos/scripts/build.sh [debug]` (plain `swiftc`; don't reintroduce SwiftPM or an Xcode project
  without checking it builds with only the Command Line Tools). The build must stay signed with
  "Flickwise Local Signing" so Accessibility and Microphone grants survive rebuilds.
- Don't store anything in the Keychain (see ARCHITECTURE.md: it prompts after every rebuild). Secrets go in
  0600 files in Application Support.
- Every feature gets an `enabled` flag (plus tunables) in `AppSettings` with a default and tolerant decoding,
  a control on the right settings page (`SettingsView.swift`: Dictation, Features, AI, General) and in the menu bar
  Features submenu if it's a toggle, and an entry in ARCHITECTURE.md's settings block. Settings live only in
  `settings.json`; modes only in `modes.json` (`ModeStore`). If a Hammerspoon setting maps to it, import it in
  `LegacyImport`.
- Popups (cards, picker, ring) are non-activating panels; their keys come from a session `EventTap` that's stopped
  before any synthetic key is posted. Read typed digits/letters from the event's characters, not key codes
  (keypad and layouts differ).
- Global shortcuts go through `GlobalHotkeys` (Carbon); re-register after any change to modes or shortcuts.
- Never do slow work inside an event-tap callback: enqueue to the main queue. Audio engine calls go on the audio queue.
- Match the file style: a header comment saying what the file does, then the type, with `// ── section ──` dividers.
- Test headless with `FLICKWISE_SUPPORT_DIR=$(mktemp -d) macos/build/Flickwise.app/Contents/MacOS/Flickwise --selftest`
  (add checks to `App/SelfTest.swift` for new logic). Check UI with `FLICKWISE_OPEN=history|settings|hud` plus a
  sandbox `FLICKWISE_SUPPORT_DIR`, and a Hammerspoon window snapshot. Never add test entries to the real history.
- Test `macos/install.sh` in a sandbox: `FLICKWISE_APPS_DIR=<tmp>/apps FLICKWISE_HS_DIR=<tmp>/hs FLICKWISE_SUPPORT_DIR=<tmp>/support FLICKWISE_SKIP_MODEL=1 FLICKWISE_NO_LAUNCH=1 bash macos/install.sh`
  (a custom apps/HS dir never stops the real app or reloads the real Hammerspoon).
- Changes to ported logic (word diff, mistakes, YAML import) are checked against the Lua code: `--diff` vs
  `hs -c` on the same cases, `--import-preview` against the real `config.yaml`. Live fixes are tested in a scratch
  TextEdit document; delete the test rows from `history.sqlite` afterwards.
- Log with `Log.info` / `Log.debug` (transcripts only at debug) to `~/Library/Logs/Flickwise/flickwise.log`.
- Speech is recognized on-device with whisper.cpp (`Transcription/`). Keep every whisper.cpp call on `WhisperEngine`'s
  queue, call `WhisperEngine.shared.shutdown()` before any exit path (ggml's Metal backend asserts otherwise), and pin
  new models and frameworks by SHA-256. The model catalog lives only in `WhisperModel.swift`; the installer reads it
  through `--model-info` / `--coreml-info`.
- Before changing recognition settings or models, measure with `Flickwise --benchmark` (and record the results in
  ARCHITECTURE.md). Don't rebuild while a benchmark is running. Check UI with `Flickwise --render <view> out.png`.
