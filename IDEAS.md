# Flickwise — Ideas & Roadmap

A running list of ideas for making Flickwise faster, easier, and nicer to use.
Tick a box when an idea is picked, and move it to **Done** when shipped.

**Effort scale:** 🟢 Easy (an hour or two) · 🟡 Medium (half a day to a day) · 🔴 Hard (multi-day / new tooling)

---

## ✅ Done

- [x] **Floating pill (HUD)**: Wispr-style pill at the bottom-center. Shows a waveform while working, a check with the time taken when done, and a red message on errors. Replaces the old `hs.alert` boxes. (`lib/hud.lua`)
- [x] **Command-palette picker (⌘⇧P)**: dark card above the pill with a selection preview, numbered modes, shortcut keycaps, type-to-filter, and 1–9 quick pick. Focus stays in your app. (`lib/mode_picker.lua`)
- [x] **Native-looking menu bar**: template sparkle icon, right-aligned shortcuts, a Features submenu, and an Advanced submenu. (`lib/menubar_ui.lua`)
- [x] **2.1 "What changed" bubble + undo**: a card above the pill shows a word-level diff after each fix. ⌘Z (configurable) restores the original while the bubble is visible, it auto-dismisses and pauses while hovered, and it can be turned off per mode. (`lib/diff_bubble.lua`, `lib/word_diff.lua`)
- [x] **3.1 Radial menu at the cursor**: hold **Right ⌥**, flick toward a mode, and release to apply. Slot 1 is at the top, then clockwise. Also supports 1–8, click, and esc. The trigger can be a right-hand modifier or a chord. (`lib/radial_menu.lua`)
- [x] **1.4 Replace without touching the clipboard**: the selection is read and replaced through Accessibility and verified. It falls back to ⌘C/⌘V automatically. Web and Electron apps are read directly but written with a paste. Undo restores through Accessibility too. (`lib/ax_text.lua`)
- [x] **Explain Meaning (⌃⌘M)**: shows what the selected text means in simple words (including requests, deadlines, and tone), plus an exact Roman Urdu translation of the text, in a two-row card, without changing the text. Built on a new per-mode `output: "show"` option and the answer card (`features.result_card`).
- [x] **Feature flags**: every optional feature is switched under `features:` in `config.yaml`, or from menu bar → Features. (`lib/features.lua`)

---

## 1. Less effort per fix

### [ ] 1.1 No need to select text 🟡
**Today:** select → shortcut → wait.
**Idea:** if nothing is selected, fix the text around the cursor automatically.

- Read the focused text field through Accessibility (`AXValue`, `AXSelectedTextRange`).
- No selection → pick the **current sentence**, or the **current paragraph**, or the **whole field** when it's short (e.g., a Slack message box).
- Select that range programmatically, then run the normal flow.

**Why:** the most common case becomes *type → tap*.
**Risk:** some apps (Electron, web editors, Terminal) expose little or no Accessibility info. Fall back to the current select-first behavior there.

---

### [ ] 1.2 One smart key instead of many 🟢
**Idea:** a single "Make it right" mode that decides what to do from the input.

| Input looks like | Action |
|---|---|
| English with mistakes | Fix grammar and spelling |
| Urdu script or Roman Urdu | Translate into natural English |
| Mixed Urdu + English | Translate and polish |
| Code | Leave unchanged (or explain it, configurable) |
| Already correct | Return unchanged |

- Mostly prompt engineering. Language detection can also be a cheap local check (Urdu Unicode range `U+0600–U+06FF`) before calling the model.
- Keep the specialized modes in the picker for when you want something specific.

**Why:** you stop remembering ⌘⇧G vs ⌘⇧U vs ⌘⇧M.

---

### [ ] 1.3 Lighter trigger 🟢
**Idea:** double-tap `⌥` (or hold `Fn`) instead of a three-key chord.

- Implement with an `hs.eventtap` on `flagsChanged`, detecting two ⌥ taps within ~300ms with no other key between.
- Configurable in `config.yaml` (`trigger: double_option | fn_hold | hotkey`).

**Risk:** conflicts with apps that use ⌥ on its own (rare). Make it opt-in.

---

### [x] 1.4 Replace without touching the clipboard 🟡 (shipped 2026-09-27, see Done)
**Today:** Cmd+C → wait ~250ms → call AI → Cmd+V → restore clipboard.
**Idea:** read and write the selection directly through Accessibility (`AXSelectedText`).

- Faster: no copy/poll delays.
- The clipboard is never touched, so no clipboard-manager noise and no risk of losing what you copied.
- Fall back to the clipboard method in apps that don't support writing `AXSelectedText`.

**Risk:** writing through AX sometimes breaks the app's own undo stack. Test per app (Slack, Chrome, Obsidian, Mail, Notes).

---

## 2. Features that help a non-native speaker

### [x] 2.1 "What changed" bubble + undo 🟡 (shipped 2026-09-27, see Done)
**Idea:** after a fix, show a small bubble near the text (or in the pill) with a word-level diff:

> Meaning a service is pushing an event ~~ton~~ **to** multiple ~~queue~~ **queues**…

- Press a key (e.g., `⌘Z` while the bubble is visible, or a dedicated hotkey) to **undo** and restore the original.
- The diff is computed locally (word-level LCS). No extra AI call.
- The bubble auto-dismisses after a few seconds, or stays while hovered.

**Why:** you see and learn from your mistakes instead of having them silently replaced. Undo makes it safe to fire without thinking.

---

### [ ] 2.2 Pick from 3 versions 🟡
**Idea:** one key returns three variants side by side. Press `1` / `2` / `3` to apply.

| 1 · Fixed | 2 · Clearer | 3 · Formal |
|---|---|---|
| minimal corrections | reworded for clarity | professional tone |

- One AI call returning JSON with three fields (cheaper than three calls).
- Rendered in the picker card, with the differences highlighted.

**Why:** you choose after seeing the result, instead of choosing a mode before.

---

### [ ] 2.3 Tone that follows the app 🟢
**Idea:** the smart key adjusts tone to the frontmost app automatically.

```yaml
app_profiles:
  Slack:     casual, short
  Mail:      professional
  Gmail:     professional
  Obsidian:  keep my style, fix only errors
  Terminal:  disabled
```

- Uses `hs.application.frontmostApplication():name()` or its bundle ID.
- Browser tabs could even be matched by window title (e.g., "Gmail", "Jira").

---

### [ ] 2.4 Personal mistake tracker 🟡
**Idea:** log what you commonly get wrong (from the diffs in 2.1) and show a small weekly summary.

- e.g., "Top mistakes this week: missing articles (a/the) ×14, plural -s ×9, *ton* → *to* ×3".
- Stored locally in a JSON file. Nothing leaves the machine except the normal AI call.
- Viewable from the menu bar ("My Progress…").

**Why:** turns a correction tool into a learning tool.

---

### [ ] 2.5 Voice → polished English (Wispr-style) 🔴
**Idea:** hold a key, speak in Urdu, English, or a mix, release, and polished English is typed into the field.

- Record audio with a small helper (`sox` / `ffmpeg` via `hs.task`, or a tiny Swift CLI).
- Send the audio straight to Gemini (it accepts audio input) with a "transcribe + translate + polish" prompt.
- The pill shows a live waveform while recording (the UI already exists).

**Risk:** needs microphone permission and an external recorder; latency depends on clip length. The biggest feature here, and possibly the biggest time-saver.

---

## 3. A "wow" UI for the picker

### [x] 3.1 Radial menu at the cursor 🟡 (shipped 2026-09-27, see Done)
**Idea:** hold the trigger key and the modes spring out in a ring around the mouse or text caret. Flick toward one and release to apply.

- Staggered spring animation (each item pops in ~30ms after the previous one).
- The direction under the pointer highlights live; releasing applies it; releasing in the center cancels.
- Muscle memory: "Fix" is always up, "Translate" always right, and so on.

**Why:** the fastest possible picker once learned, and it looks great.

---

### [ ] 3.2 Picker anchored to the text caret 🟡
**Idea:** open the palette right next to the text being edited instead of at the bottom of the screen.

- Caret position from Accessibility (`AXBoundsForRange` on the selected range). Fall back to the mouse position, then to bottom-center.
- Spring pop-in with a slight scale and blur-in; list items slide in with a stagger.

---

### [ ] 3.3 Frosted-glass surfaces 🟢
**Idea:** real "glass" look for the pill and picker.

- Hammerspoon webviews can't blur the real desktop behind them.
- Trick: take a screenshot of the area behind the popup (`hs.screen:snapshot`), put it in as the background, and blur it with CSS. It looks like native vibrancy.
- Refresh the snapshot each time the popup opens.

---

### [ ] 3.4 Live preview inside the picker 🟡
**Idea:** as you move through the modes, the card shows what the result *would* look like (fetched in the background, cached per mode).

- `Enter` applies the previewed text instantly (no second wait).
- Costs extra AI calls. Only prefetch the highlighted mode, after a short pause.

---

### [ ] 3.5 Restyle the prompt editor 🟢
**Idea:** bring the "Edit Modes…" window in line with the new look (same colors, keycaps, spacing, animations). It's the last screen still in the old style.

---

## 4. Speed & reliability

### [ ] 4.1 Streaming responses 🟡
Stream tokens from Gemini (`streamGenerateContent`) so the pill can show progress and long texts feel faster.

### [ ] 4.2 Remove fixed sleeps 🟢
Replace the fixed `usleep` delays in capture and paste with event-driven checks (pasteboard `changeCount`). Shaves ~100–250ms per run.

### [ ] 4.3 Offline / fallback model 🔴
If the network or API fails, fall back to a local model (e.g., via Ollama) for basic grammar fixes.

---

## 5. Bigger architectural option

### [ ] 5.1 Rebuild as a native Swift menu bar app 🔴
**Pros:** real macOS vibrancy/blur, smoother animations, reliable caret positioning, first-class audio for voice input, a proper installable `.app`.
**Cons:** full rewrite; needs Xcode, code signing, and Accessibility/Microphone permission handling.

**Current recommendation:** stay in Hammerspoon. Everything above except polished voice input is achievable there. Revisit if voice (2.5) becomes the main feature.

---

## Suggested first bundle

If picking a starting set, these three together turn *select → remember shortcut → wait* into *type → tap*:

1. **1.2 One smart key** + **1.3 double-tap ⌥**
2. **1.1 No need to select text**
3. ~~**2.1 "What changed" bubble + undo**~~ (done)

Then add **3.1 Radial menu** for the less common modes.

---

## Notes / decisions log

<!-- Add dated notes here as ideas are chosen, changed, or dropped. -->
- 2026-09-27 — Ideas list created after the UI refresh (pill, palette, menu bar).
- 2026-09-27 — Renamed TextFixer → **Flickwise** (Flick, Flick Write/Flickwrite, FlickType, Flik, Flickit, FlickFix, Fliq were all taken). New logo: pen nib flicking an ink check mark, with motion streaks (`assets/`).
- 2026-09-27 — Resting idle pill now defaults to **off**; the pill appears only while processing.
- 2026-09-27 — Shipped **2.1** (diff bubble + undo). Added the `features:` config section as the one place to enable or disable features. The idle pill toggle moved there from `hs.settings`. Undo defaults to the app's own ⌘Z. `undo_method: reselect` is available for apps where that misbehaves.
- 2026-09-27 — Shipped **3.1** radial menu. The trigger is **hold Right ⌥**, chosen after checking existing shortcuts: Flickwise uses ⌘⇧G/C/E/M/U/P, Wispr Flow uses Fn (push-to-talk), Fn+Space, ⌃Fn, ⌘⌃V/C and *left* ⌥+M, and ChatGPT uses ⌥Space and ⌥⇧1. Nothing uses Right ⌥ on its own. A 150 ms hold threshold keeps ⌥-character typing working.
- 2026-09-27 — Shipped **1.4** (`features.direct_replace`, on by default). Tested in TextEdit: the text was replaced and restored with a clipboard changeCount delta of 0. Web writes default to paste, because AX writes bypass the input events that web frameworks listen for. Also fixed `hs.axuielement.systemElement()`, which should be `systemWideElement()`: the old TextFixer Accessibility fallback and the radial menu's caret anchor had never worked.
- 2026-09-27 — Added **Explain Meaning** (user request: understanding what a message means). New `output: "show"` modes keep the selection untouched and show the answer in a card with a timer, hover-to-hold, and Copy. The hotkey is ⌃⌘M, since ⌘⇧M is Clarify Message and ⌃⌘M is free on this Mac. Idea for later: "Explain Code" could also become a show mode instead of replacing the code.
