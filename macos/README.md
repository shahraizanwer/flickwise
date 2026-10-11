# Flickwise for macOS (native app)

A small, fast menu bar app: **hold a key, speak, let go**, and your words are typed
wherever you're working. Speech is recognized **on your Mac** with Whisper large-v3-turbo
(the model Voicebox uses), so there's no network round trip, no rate limit, and no API key.
Everything you say is also kept in a searchable **Voice History** on your Mac.

It replaces the Hammerspoon version's dictation. The text-fix modes (Fix Grammar,
the radial menu, Reply Helper…) still run in Hammerspoon for now and will move
here feature by feature (see `IDEAS.md`, section 5).

## Install

On any Mac with macOS 13.3+ (the Xcode Command Line Tools are enough, no Xcode needed):

```bash
git clone https://github.com/shahraizanwer/flickwise.git ~/Developer/flickwise
~/Developer/flickwise/macos/install.sh
```

Or in one line, without keeping a checkout:

```bash
curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/macos/install.sh | bash
```

> **With Claude Code on another Mac:** ask *"Clone github.com/shahraizanwer/flickwise and
> run macos/install.sh"*. The installer is non-interactive, so this works as is.

The installer builds the app from source, installs it to `~/Applications/Flickwise.app`,
downloads the speech model (Whisper large-v3-turbo, ~870 MB, checksum-verified, once),
switches off the Hammerspoon version's dictation (if it's there), and opens the app.
For ~25% faster recognition, add the Neural Engine encoder (+1.2 GB; the first launch
spends ~2 minutes preparing it, once):

```bash
FLICKWISE_NEURAL_ENGINE=1 ~/Developer/flickwise/macos/install.sh
```

(or Settings → Speech recognition → Neural Engine boost → Download). The first launch shows a
setup window for:

1. **Accessibility**: to notice the key you hold and type into other apps
2. **Microphone**: used only while you hold the key
3. **Speech recognition**: already done if the installer downloaded the model. Otherwise download
   it there, or switch to Gemini (cloud) and paste an API key. On a Mac that has the Hammerspoon
   version, your dictation settings (and Gemini key, if any) are imported automatically.

To update, run the installer again. Settings, the key, and history are kept.

## Use it

| Do this | What happens |
|---|---|
| Hold **Right ⌘** (configurable), speak, release | An island grows out of the notch (Flicky the mascot listens, with a live waveform), then the text is typed at your cursor |
| **Esc** while holding | Cancel; nothing is typed |
| Quick tap, or Right ⌘ + another key | Nothing (it's a normal shortcut) |
| Menu bar waveform → **Voice History…** | Search everything you've said, with Copy, Original transcript, Retry, and Delete |
| Menu bar → **Style** | Verbatim · Clean up (removes um/uh) · Polished English |

If recognition fails, the recording is **kept** and shows up in Voice History with a **Retry**
button, so nothing you say is lost.

## Speech recognition

| Setting (Settings → Speech recognition) | |
|---|---|
| **On this Mac (Whisper)**, the default | Private and offline. Large v3 Turbo: ~1.8 s from release to text on an M1 Pro, ~1.3 s with the Neural Engine boost. English, Urdu and Hindi. |
| Other models | *Small* is 3–4× faster and fine for English, but weaker in Urdu/Hindi. *Turbo compressed* (574 MB) and *Turbo full* (1.6 GB) give the same text. |
| Gemini (cloud) | Optional. Needs an API key; slower (network) and rate-limited. |
| Polish with Gemini | Optional: speech stays local, only the text goes to Gemini for Clean up / Polished English. |

Turbo doesn't translate: with *Polished English*, Urdu/Hindi speech comes out in its own
language unless you pick *Small* (Whisper's built-in translation) or turn on Gemini polish.
Full measurements are in `ARCHITECTURE.md` → *Speech recognition: measurements*.

Compare recognizers on your own recordings:

```bash
macos/build/Flickwise.app/Contents/MacOS/Flickwise --benchmark --gemini my-clip.m4a other.wav
```

## Why it's fast

- **No start-up delay:** audio comes straight from `AVAudioEngine` into memory. There's no
  ffmpeg process to launch and no temp file. With *instant start* on (the default), the mic
  starts the moment the key goes down, so your first word is never clipped. A tap simply
  throws that audio away.
- **No network:** Whisper runs on the Mac's GPU (or Neural Engine).
- **Light when idle:** the model (~1 GB) is loaded only while you dictate. Loading takes ~0.6 s
  and happens while you're still talking, then it's freed (~65–150 MB when idle). To keep it in
  memory instead, turn on Settings → *Keep the model in memory*.
- **Silence is skipped:** a speech check runs before recognition, so a stray press never types
  Whisper's classic "Thank you." (or Gemini's invented sentences).
- **Small native binary:** about 1 MB of Swift plus the whisper.cpp framework, AppKit and SwiftUI only.

## Where things live

| What | Where |
|---|---|
| App | `~/Applications/Flickwise.app` |
| Settings | `~/Library/Application Support/Flickwise/settings.json` (hand-editable; also in the Settings window) |
| Speech models | `~/Library/Application Support/Flickwise/models/` (delete them in Settings) |
| Gemini API key (optional) | `~/Library/Application Support/Flickwise/gemini_api_key` (only readable by you) |
| Voice history | `~/Library/Application Support/Flickwise/history.sqlite` (+ `audio/` for kept recordings) |
| Log | `~/Library/Logs/Flickwise/flickwise.log` |

With on-device recognition nothing leaves your Mac. Only if you choose Gemini (or Gemini
polish) is audio or text sent to Google.

## Develop

```bash
macos/scripts/build.sh          # optimized build → macos/build/Flickwise.app (fetches whisper.cpp once)
macos/scripts/build.sh debug    # faster compile
open macos/build/Flickwise.app

# headless checks against a throwaway data folder (your real history is untouched)
FLICKWISE_SUPPORT_DIR=$(mktemp -d) macos/build/Flickwise.app/Contents/MacOS/Flickwise --selftest
# run the dictation pipeline (current settings) on a file
say -o /tmp/t.wav --data-format=LEI16@16000 "um, testing one two" && \
  macos/build/Flickwise.app/Contents/MacOS/Flickwise --transcribe /tmp/t.wav
# draw a window offscreen to check the UI
macos/build/Flickwise.app/Contents/MacOS/Flickwise --render settings /tmp/settings.png
```

See `ARCHITECTURE.md` → *Native app* for the module map and the reasoning behind
the build and signing setup.

## Uninstall

Quit Flickwise from its menu, then:

```bash
rm -rf ~/Applications/Flickwise.app ~/Library/Logs/Flickwise
security delete-keychain ~/Library/Application\ Support/Flickwise/signing/flickwise-signing.keychain-db
rm -rf ~/Library/Application\ Support/Flickwise   # also deletes your voice history, models and key
```
