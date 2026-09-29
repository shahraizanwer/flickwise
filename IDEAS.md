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
- [x] **2.4 Fix history + personal mistake tracker**: menu bar → History & Progress…. It keeps a searchable local history of fixes and answers, plus My Progress (mistake types, repeated corrections, weekly trend). Stored per Mac, never uploaded. (`lib/history.lua`, `lib/history_window.lua`)
- [x] **Minimal Fix (⌃⌘G)**: the closest correct sentence. It fixes only real mistakes with the fewest changes and never rephrases, so a learner sees exactly what was wrong instead of feeling the whole sentence was bad. It runs at temperature 0 (new per-mode `temperature` setting).
- [x] **6.12 Reply Helper (⌃⌘R)**: select a message you received and get its meaning plus 3 replies (Short / Detailed / Polite no). Press 1–3 or click to insert one at your cursor, or Copy it. (`output: "replies"`, reply card in `diff_bubble.lua`)
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

### [x] 2.4 Personal mistake tracker 🟡 (shipped 2026-09-27, see Done)
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

## 6. Learn English while you work (Flickwise as a teacher)

**Goal:** use Flickwise all day for real work (messages, emails, AI prompts) *and* get better at English quickly, without slowing work down. Every fix becomes a tiny lesson, your own mistakes become your practice material, and the teaching can be turned up or down per app.

All of these build on what already exists: the diff bubble (2.1), the history + My Progress (2.4), the answer card (Explain Meaning), and the radial menu (3.1). Each one gets a switch under `features:`.

### A. Learn from every fix (in the flow, zero extra effort)

### [ ] 6.1 "Why?" behind every correction 🟡
**Idea:** in the diff bubble, hover a change (or press `?`) to see a one-line rule in simple English, optionally with Roman Urdu underneath.

> ~~has went~~ **went**: "went" is already past tense. Use *has gone* or just *went*.

- Ask for the reasons in the same AI call (JSON: `{ result, changes: [{ from, to, why }] }`), or fetch them lazily only when you hover, to keep fixes fast.
- Store `why` in the history, so the History tab shows the rule next to each mistake.
- `features.teacher.explain: off | hover | always`, `explain_language: english | english+roman_urdu`

**Why:** you learn the rule, not just the answer. That's the biggest difference between a fixer and a teacher.

---

### [ ] 6.2 Teacher level per app (silent · explain · coach) 🟢
**Idea:** one setting decides how much teaching happens, and it can differ by app:

| Level | Behavior |
|---|---|
| `silent` | just fix it (busy moments) |
| `explain` | fix + "why" on hover (default) |
| `coach` | try-first (see 6.3) |

```yaml
teacher:
  level: explain
  apps: { Slack: explain, Mail: coach, Terminal: silent }
```
Holding ⇧ while triggering could temporarily switch to `silent` when you're in a hurry.

---

### [ ] 6.3 Coach mode: try it yourself first 🟡
**Idea:** instead of fixing right away, Flickwise **underlines** the words that are wrong (without the answer) in the bubble. You fix them in place, press the hotkey again, and it tells you what you got right, then fixes anything left.

- Hints on demand: 1st press = underline, 2nd = hint ("tense"), 3rd = answer.
- Scored in My Progress ("You fixed 4 of 6 yourself this week").

**Why:** recalling a correction teaches far more than reading one. Use it where there's no time pressure (emails, docs).

---

### [ ] 6.4 "You keep doing this" pattern alerts 🟢
**Idea:** when history shows the same mistake type 3+ times in a week, the bubble adds a short tip once a day:

> 📌 3rd time this week: **articles**. Use *a/an* the first time you mention a thing, *the* after that.

Pure local logic on `history.stats()`. The tip text comes from a small built-in rule list, or from the AI once per category.

---

### [ ] 6.5 Listen to it 🟢
**Idea:** a 🔊 button in the diff bubble and the answer card reads the corrected sentence aloud with the macOS voice (`hs.speech`). It helps with pronunciation and rhythm.

- Setting: voice + speed (a slower speed helps learners).

---

### B. Practice with your own mistakes

### [ ] 6.6 Daily 2-minute review (spaced repetition) 🟡
**Idea:** flashcards made automatically from **your own** past mistakes: you see your original sentence and type the corrected version, and Flickwise checks it word by word (reusing `word_diff`).

- Leitner/SM-2 scheduling: cards you get right come back later, mistakes come back sooner.
- A small due-count badge in the menu bar (e.g. `✦ 5`), plus an optional morning reminder.
- Opens in the History window as a third tab, **Practice**. Only mistakes from `mistake_modes` become cards, and a "Don't teach me this" button removes one.

**Why:** your own sentences are the most relevant practice material there is, and 2 minutes a day compounds fast.

---

### [ ] 6.7 Weekly focus drill 🟡
**Idea:** once a week, take your #1 mistake type (e.g. *articles*) and have the AI write 5 new work-style sentences with that exact error for you to fix. Only the category is sent to the AI, not your messages.

---

### [ ] 6.8 Weekly report card 🟡
**Idea:** every Friday, a short summary in the History window (optionally as a notification):
- 3 things that improved ("plural -s mistakes down 60%")
- 3 things to work on
- 1 rule to learn next week, with examples

It's built from `history.stats()`. Only mistake pairs (e.g. "ton → to"), never full messages, go to the AI for the wording.

---

### C. Sound natural & professional

### [ ] 6.9 "Say it better" suggestion 🟢
**Idea:** after a fix, the bubble *optionally* shows one more natural or more professional way to say it, **without applying it**. Press `Tab` (or click) to use it instead.

> ✓ *Please revert me by EOD.* → *Please reply by end of day.*

**Why:** grammar-correct isn't the same as natural. This is how vocabulary actually grows.

---

### [ ] 6.10 South Asian English → international English 🟢
**Idea:** gently flag common Pakistani/Indian English phrases that confuse international colleagues, and explain the alternative:

| You wrote | Readers expect | Why |
|---|---|---|
| revert (meaning "reply") | reply / get back to you | "revert" means "go back to a previous state" |
| do the needful | please take care of it | sounds dated/unclear |
| prepone | move earlier | not standard outside South Asia |
| I have a doubt | I have a question | "doubt" means disbelief |
| kindly do X | please do X | "kindly" can sound demanding |

Built into the Fix Grammar prompt plus a small local list (so it can be counted in My Progress as its own category, **Regional phrasing**).

---

### [ ] 6.11 Tone check before sending 🟢
**Idea:** a show-mode (`output: "show"`) for **your own** message: *"How will this sound to the reader?"* The card shows the tone ("a bit demanding", "friendly", "unclear ask") and one softer or clearer version you can apply with one click.

**Why:** at work, tone mistakes cost more than grammar mistakes, and they're the hardest to notice in a second language.

---

### [x] 6.12 Reply helper 🟡 (shipped 2026-09-30, see Done)
**Idea:** select a message you **received** and get the meaning (like Explain Meaning) plus **2–3 ready replies** (short / detailed / polite no). Press `1`/`2`/`3` to paste one, then edit. Builds on 2.2 (pick from 3 versions).

---

### [ ] 6.13 Prompt polisher 🟢
**Idea:** a mode for AI prompts (ChatGPT, Claude, Cursor…): it rewrites your prompt so it's clear and well structured (goal, context, constraints, output format), and the bubble explains *what* made it better, so your prompting and your English improve together.

---

### [ ] 6.14 Personal phrasebook 🟡
**Idea:** a ⭐ button in the bubble or card saves a good phrase (e.g. *"Could you take a look when you get a chance?"*) with its meaning in Roman Urdu. The phrasebook is searchable in the History window and insertable from the ⌘⇧P picker.

---

### [ ] 6.15 My words: don't "fix" these 🟢
**Idea:** a personal dictionary of product names, acronyms, and team jargon (`dictionary: ["Flickwise", "PR", "EOD"]`) that the AI must keep as-is. It also keeps these out of the mistake stats.

---

### D. Motivation & measuring progress

### [ ] 6.16 Progress score, streaks & goals 🟡
**Idea:** make improvement visible in My Progress:
- **Clean-message rate:** % of fixes that needed *no* change (your "accuracy"). The target trend is up.
- **Streak:** days in a row with a practice session (6.6).
- **Goal:** e.g. "under 1 mistake per message this month", with a progress ring.
- **Level estimate:** once a month the AI estimates your CEFR level (A2 → C1) from a few anonymized mistake samples, and shows the trend.

---

### [ ] 6.17 Then vs now 🟢
**Idea:** once a month, show one of your older messages next to a recent one of the same kind, with mistake counts, so you can *see* the improvement. Motivating, and local only.

---

### Privacy rules for all learning features
- Everything stays in `data/` on each Mac (same as 2.4).
- Features that call the AI send **mistake pairs or categories only**, never full messages, unless the feature is about the current selection (6.1, 6.9, 6.11–6.13), which is the same text you already chose to send.
- Each feature is switchable under `features.teacher` / `features.practice`.

### Suggested learning roadmap
1. **Quick wins (this week):** 6.1 "Why?" on hover · 6.5 Listen · 6.10 regional phrasing · 6.4 pattern alerts
2. **Daily habit:** 6.6 two-minute review + 6.16 streak/clean-message rate
3. **Professional polish:** 6.11 tone check · 6.9 say it better · 6.13 prompt polisher
4. **Deeper learning:** 6.3 coach mode · 6.2 teacher levels per app · 6.8 weekly report

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
- 2026-09-27 — Added **Explain Meaning** (user request: understanding what a message means). New `output: "show"` modes keep the selection untouched and show the answer in a card with a timer, hover-to-hold, and Copy. The hotkey is ⌃⌘M, since ⌘⇧M is Clarify Message and ⌃⌘M is free on this Mac.
- 2026-09-27 — Shipped **2.4** as fix history + My Progress. Decided on **one tracker per Mac** (local `data/history.jsonl`, git-ignored). That keeps work text on the work laptop, needs no server, and gives every user their own tracker automatically. Full text is stored (the user wants to browse past messages), with 90-day retention, `exclude_apps`, and Clear all. A possible later addition is Export/Import to combine Macs. A clipboard history (Windows + V style) was considered and skipped for now, because macOS 26 has one built into Spotlight (⌘Space, then ⌘4).
- 2026-09-29 — Added section **6. Learn English while you work** (teacher features). The goal is fast English improvement during real professional use: explanations per fix, coach mode, spaced repetition from your own mistakes, tone check, reply helper, prompt polisher, regional phrasing, and progress scores. See its roadmap for the suggested order.
- 2026-09-29 — Added **Minimal Fix** (user request: rephrasing everything is discouraging, and the closest correct sentence builds confidence). Compared with Fix Grammar on real samples, it keeps the learner's words (e.g. "told me" instead of "said", keeps "since morning"). Added a per-mode `temperature` (Minimal Fix = 0). Counted in My Progress by default.
- 2026-09-30 — Removed the **Explain Code** mode (never used). This frees ⌘⇧E and a radial slot.
- 2026-09-30 — Shipped **6.12 Reply Helper**. The card stays open on outside clicks so you can click into the reply box. The number keys only work until you type, so typed digits are never swallowed. Replies are inserted at the caret through Accessibility (clipboard untouched) or by paste. Tested in TextEdit: pressing 1 inserted reply 1 with a clipboard changeCount delta of 0. The prompt was tuned to reuse facts from the message (e.g. "3pm") instead of placeholders.
