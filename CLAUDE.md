# Flickwise: instructions for Claude

Flickwise is a Hammerspoon (Lua 5.4) tool: select text in any macOS app, press a
hotkey, and the text is replaced with an AI-transformed version. Start with
`ARCHITECTURE.md` for the module map and data flow, and see `IDEAS.md` for the roadmap.

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
   and of company-internal names or details.
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
