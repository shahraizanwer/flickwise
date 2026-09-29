<p align="center"><img src="assets/flickwise-logo.svg" width="160" alt="Flickwise logo"></p>

# Flickwise

Select text in **any macOS app** (Slack, Mail, Notes, a browser, anything), press a hotkey, and the text is replaced in place with an AI-improved version: grammar fixed, made concise, translated, and so on. A small bubble then shows exactly what changed, and **⌘Z** puts the original back.

Flickwise runs inside [Hammerspoon](https://www.hammerspoon.org) (a free macOS automation app) and uses **Google Gemini** (free API key) or the **Glean CLI**.

---

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/install.sh | bash
```

The installer:
- installs Hammerspoon with Homebrew if it's missing (otherwise it tells you where to download it)
- clones Flickwise into `~/.hammerspoon/flickwise`
- creates your `config.yaml`
- hooks Flickwise into Hammerspoon and reloads it

**Run the same command again at any time to update.** Your `config.yaml` (API key, modes) is never overwritten.

Then, the first time on a Mac:
1. **Allow Accessibility:** System Settings → Privacy & Security → Accessibility → turn on **Hammerspoon**. Without it, Flickwise can't copy or paste for you.
2. **Add a Gemini API key:** a setup window opens automatically. Get a free key at <https://aistudio.google.com/app/apikey>. (Using Glean instead? See *AI backend* below.)
3. Select some text and press **⌘⇧G**.

<details>
<summary>Prefer to clone it yourself?</summary>

```bash
git clone https://github.com/shahraizanwer/flickwise.git ~/.hammerspoon/flickwise
~/.hammerspoon/flickwise/install.sh
```
Or double-click `install.command` in Finder.
</details>

### Upgrading from TextFixer

TextFixer is the old name of this project. Run the same install command. It detects `~/.hammerspoon/textfixer` and:
- copies your TextFixer `config.yaml` (modes, hotkeys, API key or Glean path) into Flickwise
- moves the old folder (and `~/Applications/TextFixer.app`, if present) to `~/.hammerspoon/textfixer.backup.<date>`
- swaps `require("textfixer")` for `require("flickwise")` in `~/.hammerspoon/init.lua` (the old file is backed up)
- adds the new `features:` settings to your config

Nothing is deleted. To roll back, move the backup folder back to `~/.hammerspoon/textfixer` and restore `init.lua` from `init.lua.backup.<date>`.

### Installing with Claude Code

On another Mac, paste this into Claude Code:

> Install Flickwise on this Mac by running `curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/install.sh | bash`. If I have an old TextFixer install, the script migrates it automatically. Show me the installer output, then tell me which of the "first time on a Mac" steps from https://github.com/shahraizanwer/flickwise#install-one-command I still need to do. Don't print my API key.

---

## AI backend

| Backend | Setup |
|---|---|
| **Gemini** (default) | Put your key in `gemini_api_key` in `config.yaml`, or use the setup window (menu bar → **API Key…**). `gemini_model` picks the model. |
| **Glean CLI** | `brew install gleanwork/tap/glean-cli && glean auth login`, then set `glean_binary_path: "/opt/homebrew/bin/glean"` (Intel Macs: `/usr/local/bin/glean`). When this is set, Glean is used instead of Gemini. |

---

## Usage

1. In any app, **select some text**.
2. Press the hotkey for the transformation you want.

| Mode | Hotkey | What it does |
|---|---|---|
| Fix Grammar | `⌘⇧G` | Fixes grammar, spelling, and awkward phrasing; keeps tone and formatting |
| Minimal Fix | `⌃⌘G` | The **closest correct version**: fixes only real mistakes and never rephrases, so the diff shows exactly what you got wrong |
| Make Concise | `⌘⇧C` | Cuts the text by ~40% while keeping all meaning |
| Clarify Message | `⌘⇧M` | Rewrites the message so it's clear and unambiguous |
| Urdu to English | `⌘⇧U` | Translates Urdu into natural English |
| Reply Helper | `⌃⌘R` | For a message you received: its meaning + 3 ready replies. Press 1–3 to insert one |
| Explain Meaning | `⌃⌘M` | Shows what the text means in simple words, plus an exact Roman Urdu translation. **Doesn't change the text** |
| *(all modes)* | `⌘⇧P` | Command palette: pick any mode |

Or **hold Right ⌥** and flick toward a mode (see *Radial menu* below).

The selected text is replaced in place. Your clipboard is left alone: Flickwise writes into the text field directly, and when it has to fall back to copy/paste, it puts your clipboard back afterwards.

### The floating pill
When a mode runs, a pill appears at the bottom-center of your screen with a live waveform and the mode name, then a green check with how long it took (or a red message if something went wrong). It is hidden while idle. To keep a small resting pill on screen, turn on **menu bar → Features → Resting Pill When Idle**.

### "What changed" bubble + undo
After a fix, a card above the pill shows what changed word by word: removed words are struck through in red, and added words are shown in green. While it's visible:

| Action | Result |
|---|---|
| `⌘Z` (or click **Undo**) | Restore the original text |
| Any other key / click elsewhere | Keep the change and close the bubble |
| Hover the bubble | Hold it open while you read; the countdown pauses |
| Move the mouse away | The countdown continues from where it stopped |

A blue bar along the bottom drains to show when it will close (after `duration_seconds`, 6 by default). Turn it off from **menu bar → Features**, or for a single mode with `diff_bubble: false`.

### Radial menu (hold Right ⌥)
Select text, then **hold the Right ⌥ (Option) key**. Your modes spring out in a ring around the mouse pointer. Move toward one (it highlights) and **let go** to apply it.

| While holding | Result |
|---|---|
| Move toward a mode, release ⌥ | Apply that mode |
| Release with the pointer in the center | Cancel |
| Press `1`–`8` | Apply that mode directly |
| Click | Apply the highlighted mode |
| `esc` / right-click | Cancel |

The first mode is always at the top and the rest go clockwise, so the directions become muscle memory. Choose which modes appear, and in what order, with `features.radial_menu.modes`. A quick tap of Right ⌥ does nothing, and ⌥-characters (like ⌥E) still type normally. Prefer a chord? Set `trigger: ["ctrl", "alt", "space"]`.

### Explain Meaning (understand a message)
Select any text, whether it's a message someone sent you or something you wrote, and press **⌃⌘M** (or pick *Explain Meaning* in the radial menu or ⌘⇧P). A card shows two rows:
- **Meaning:** what it means in 1–3 simple sentences, including whether they're asking for something, a deadline, or the tone
- **Roman Urdu:** an exact translation of the selected text into Roman Urdu

**Your text is never changed.** Hover to keep the card open, click **Copy** to copy the explanation, or press any key to close it.

You can turn any mode into a "show" mode like this with `output: "show"`:

```yaml
  - name: "Summarize"
    hotkey: ["ctrl", "cmd", "s"]
    output: "show"            # show the answer in a card instead of replacing the text
    system_prompt: |
      Summarize this in one short sentence.
```

### History & My Progress
Menu bar → **History & Progress…** opens a window with:
- **History:** every fix and every Explain Meaning answer, newest first, with the app and time. Search it, open an entry to see the red/green diff and the mistakes it contained, and **Copy original**, **Copy fixed**, or **Delete** it.
- **My Progress:** fixes and mistakes this week vs last week, your mistake types (spelling, articles a/an/the, singular/plural, verb forms, prepositions…), the corrections you repeat most (e.g. *ton → to ×3*), and a weekly chart.

History is saved **only on this Mac** (`~/.hammerspoon/flickwise/data/`), so it's never uploaded or pushed to GitHub, and each of your Macs keeps its own. It's kept for 90 days by default. Only the modes listed in `mistake_modes` (Fix Grammar by default) count toward My Progress, and fixes you undo don't count. Use **Clear all history** in the window to wipe it.

### Reply Helper (answer a message)
Select a message someone sent you and press **⌃⌘R**. A card shows **what it means** plus **3 ready replies**: *Short*, *Detailed*, and *Polite no / not now*. They're in simple, natural English (or Roman Urdu if the message was in Urdu).

| Do this | Result |
|---|---|
| Press `1`, `2`, or `3` right away | Inserts that reply where your text cursor is |
| Click in your reply box, then click a reply | Inserts it there (the card stays open while you click) |
| **Copy** next to a reply | Copies it |
| `esc` / ✕ | Closes the card |

Once you start typing, the number keys work normally again. The card stays up for 45 seconds (hover to keep it open). Settings: `features.reply_helper`.

### Replace without the clipboard
Flickwise reads the selected text and writes the result **directly into the text field** through macOS Accessibility. There's no ⌘C/⌘V, so your clipboard keeps whatever you copied, and it's faster. Where an app doesn't support that, it falls back to copy/paste automatically (and restores your clipboard).

In web pages and Electron apps (Chrome, Safari pages, Slack, VS Code…), the result is pasted rather than written directly, because web apps can miss direct writes. If an app misbehaves, add it to `exclude_apps`.

### Features (turn things on or off)
Every optional feature lives under `features:` in `config.yaml`, and the on/off switches are also under **menu bar → Features**:

```yaml
features:
  idle_pill:
    enabled: false
  diff_bubble:
    enabled: true
    duration_seconds: 6
    undo_hotkey: ["cmd", "z"]
    undo_method: "app"        # app | reselect
    context_words: 8
  radial_menu:
    enabled: true
    trigger: "right_option"   # right_option | right_command | right_control | right_shift | ["ctrl","alt","space"]
    hold_ms: 150
    anchor: "mouse"           # mouse | caret
    modes: []                 # e.g. ["Fix Grammar", "Urdu to English"]; empty = all (max 8)
  history:
    enabled: true             # local fix history + My Progress (this Mac only)
    retention_days: 90
    exclude_apps: []          # never record these apps, e.g. ["1Password"]
    mistake_modes: ["Fix Grammar", "Minimal Fix"]
  reply_helper:
    enabled: true             # Reply Helper card (off = plain answer card)
    duration_seconds: 45
  result_card:
    enabled: true             # answer card for "show" modes (off = copy the answer to the clipboard)
    duration_seconds: 15
  direct_replace:
    enabled: true             # no clipboard: read/replace through Accessibility
    web_content: "paste"      # paste | direct (for web pages & Electron apps)
    exclude_apps: []          # e.g. ["Terminal"] to always use copy/paste
```

### Mode picker (`⌘⇧P`)
Select text, press `⌘⇧P`, and a palette opens just above the pill with a preview of your selection. Your cursor stays in the app you were typing in.

| Key | Action |
|---|---|
| `1`–`9` | Apply that mode immediately |
| `↑` `↓` / `⌃N` `⌃P` / `Tab` | Move the selection |
| `↵` | Apply the highlighted mode |
| type letters | Filter modes by name |
| `esc` or `⌘⇧P` again | Close (clipboard is restored) |

> **Known limitation:** Clicking a mode in the ✨ menu bar dropdown uses the **last focused window**, which may not be where you want the text replaced. Always use hotkeys for reliable in-place replacement.

---

## Adding a new mode

Open `~/.hammerspoon/flickwise/config.yaml` and add an entry to the `modes` list:

```yaml
modes:
  # ... existing modes ...

  - name: "Translate to Spanish"
    hotkey: ["cmd", "shift", "s"]
    system_prompt: |
      Translate the following text to Spanish. Return only the translation.
      Preserve formatting, tone, and any markdown.
```

Save the file. Flickwise detects the change and reloads within ~1 second — no Hammerspoon restart needed. You can also add and edit modes from **menu bar → Edit Modes…**.

**Optional per-mode settings:**
- `temperature: 0` (Gemini only, 0–2) makes a mode more literal. Minimal Fix uses 0, and the default is 0.2.
- `output: "show"` shows the answer in a card instead of replacing the text. `output: "replies"` expects JSON `{ "meaning": …, "replies": [{ "label": …, "text": … }] }` and shows pickable replies (see Reply Helper).
- `diff_bubble: false` turns off the "what changed" bubble for that mode.

**Per-mode timeout override:**
```yaml
  - name: "Long Summary"
    hotkey: ["cmd", "shift", "l"]
    timeout_seconds: 60
    system_prompt: |
      Summarize this document in detail. Return only the summary.
```

---

## Troubleshooting

**Hotkey does nothing / text isn't replaced**
- Check that Hammerspoon has **Accessibility** permission (System Settings → Privacy & Security → Accessibility). After an update, toggle it off and on again.
- Check the log: menu bar → **Advanced → Open Logs**, or `open ~/.hammerspoon/flickwise/flickwise.log`.

**"Select some text first" even though text is highlighted**
- Flickwise reads the selection through Accessibility first, then falls back to ⌘C. Some apps are slow to put the selection on the clipboard: try again, or select a bit more text.

**Text replaced oddly in one particular app**
- Add the app to `features.direct_replace.exclude_apps` (e.g. `["Terminal"]`) to make it always use copy/paste.

**"API key not set" / "Invalid API key"**
- Menu bar → **API Key…**, or edit `gemini_api_key` in `config.yaml` (it reloads on save).

**Glean errors**
- Run `glean auth login` again, then menu bar → **Advanced → Reload Config**.

**The response starts with "Here's the corrected version:"**
- Add to the mode's prompt: `Output the result as the very first character of your response. No preamble.`

**Hotkey conflicts with another app**
- Change the mode's `hotkey` in `config.yaml`. It hot-reloads on save.

**Hammerspoon errors**
- Hammerspoon menu bar icon → **Console**. Flickwise messages start with `[Flickwise]`.

**Debug logging**
- Set `debug: true` under `defaults:` to log every step. It logs your text, so turn it off when you're done.

---

## Update / uninstall

```bash
# Update: run the installer again (or: git -C ~/.hammerspoon/flickwise pull)
curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/install.sh | bash

# Uninstall
rm -rf ~/.hammerspoon/flickwise ~/Applications/Flickwise.app
sed -i '' '/require("flickwise")/d' ~/.hammerspoon/init.lua
# then Hammerspoon menu bar icon → Reload Config
```

---

## Contributing / how it works

- [`ARCHITECTURE.md`](ARCHITECTURE.md): modules, data flow, config shape, and how to add a feature
- [`IDEAS.md`](IDEAS.md): roadmap
- [`CLAUDE.md`](CLAUDE.md): rules for working on this repo with Claude Code (every feature is switchable under `features:`, and `ARCHITECTURE.md` stays up to date)

```
~/.hammerspoon/
├── init.lua                  # loads Flickwise: require("flickwise")
└── flickwise/                # this repo
    ├── init.lua              # entrypoint
    ├── config.yaml           # your settings + API key (git-ignored)
    ├── config.example.yaml   # template
    ├── data/                 # your local fix history (git-ignored)
    ├── install.sh            # installer / updater
    ├── assets/               # logo + menu bar icon
    └── lib/                  # modules (see ARCHITECTURE.md)
```
