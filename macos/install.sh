#!/usr/bin/env bash
# Flickwise for macOS (native app) — installer / updater. Safe to run again at any time.
#
#   From a checkout:   macos/install.sh
#   Or in one line:    curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/macos/install.sh | bash
#
# What it does:
#   1. Checks macOS 13+ and the Xcode Command Line Tools (swiftc)
#   2. Without a checkout, clones/updates the repo in ~/Library/Application Support/Flickwise/source
#   3. Builds Flickwise.app from source (macos/scripts/build.sh), signed with a local
#      certificate so macOS keeps its permissions across updates
#   4. Quits a running copy and installs it to ~/Applications/Flickwise.app
#   5. Downloads the on-device speech model (Whisper large-v3-turbo, ~870 MB, checksum-verified;
#      skipped when it's already there)
#   6. Turns off the Hammerspoon version's dictation (so the two don't both listen)
#   7. Opens Flickwise (the first launch shows a short setup window)
#
# Your settings, API key (Keychain) and voice history live outside the app and are never touched.
#
# Environment overrides:
#   FLICKWISE_REPO        git URL (default: https://github.com/shahraizanwer/flickwise.git)
#   FLICKWISE_BRANCH      branch (default: main)
#   FLICKWISE_SRC         where to keep the source when run without a checkout
#   FLICKWISE_APPS_DIR    install folder (default: ~/Applications)
#   FLICKWISE_HS_DIR      Hammerspoon config dir (default: ~/.hammerspoon)
#   FLICKWISE_MODEL       speech model id (default: large-v3-turbo-q8_0; see `Flickwise --model-info`)
#   FLICKWISE_SKIP_MODEL=1  don't download a speech model (download it later from Settings)
#   FLICKWISE_NEURAL_ENGINE=1  also download the model's Neural Engine encoder (~1.2 GB, ~25% faster;
#                              the first launch spends ~2 min preparing it, once)
#   FLICKWISE_SUPPORT_DIR   data folder (default: ~/Library/Application Support/Flickwise)
#   FLICKWISE_NO_LAUNCH=1 don't open the app at the end
#   FLICKWISE_KEEP_HS_DICTATION=1  leave the Hammerspoon dictation setting alone
set -euo pipefail

REPO="${FLICKWISE_REPO:-https://github.com/shahraizanwer/flickwise.git}"
BRANCH="${FLICKWISE_BRANCH:-main}"
SRC="${FLICKWISE_SRC:-$HOME/Library/Application Support/Flickwise/source}"
APPS_DIR="${FLICKWISE_APPS_DIR:-$HOME/Applications}"
HS_DIR="${FLICKWISE_HS_DIR:-$HOME/.hammerspoon}"
BUNDLE_ID="app.flickwise.mac"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -t 1 ]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else
    G=""; Y=""; R=""; B=""; D=""; X=""
fi
ok()   { echo "  ${G}✓${X} $*"; }
warn() { echo "  ${Y}!${X} $*"; }
info() { echo "  ${D}→ $*${X}"; }
step() { echo; echo "${B}$*${X}"; }
die()  { echo "  ${R}✗ $*${X}" >&2; exit 1; }

echo
echo "${B}Flickwise for macOS — installer${X}"

# ── 1. Requirements ──────────────────────────────────────────────────────────
step "Checking requirements"
[ "$(uname -s)" = "Darwin" ] || die "Flickwise runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || die "macOS 13 or later is required (you have $(sw_vers -productVersion))."
ok "macOS $(sw_vers -productVersion)"
if ! xcrun --find swiftc >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "The Xcode Command Line Tools are needed to build Flickwise. Finish the install that just opened, then run this again."
fi
ok "Swift $(swiftc --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)"

# ── 2. Source ────────────────────────────────────────────────────────────────
HERE=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$HERE" ] && [ -f "$HERE/scripts/build.sh" ]; then
    MAC_DIR="$HERE"
    ok "Building from $(cd "$MAC_DIR/.." && pwd)"
else
    step "Getting the source"
    command -v git >/dev/null 2>&1 || die "git is missing (it comes with the Command Line Tools)."
    if [ -d "$SRC/.git" ]; then
        git -C "$SRC" pull --ff-only --quiet origin "$BRANCH" && ok "Updated the source" \
            || warn "Couldn't update the source (offline?) — building the copy you have."
    else
        mkdir -p "$(dirname "$SRC")"
        git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$SRC" || die "git clone failed: $REPO"
        ok "Cloned $REPO"
    fi
    MAC_DIR="$SRC/macos"
fi

# ── 3. Build ─────────────────────────────────────────────────────────────────
step "Building Flickwise.app"
"$MAC_DIR/scripts/build.sh" release | sed 's/^/  /'
BUILT="$MAC_DIR/build/Flickwise.app"
[ -x "$BUILT/Contents/MacOS/Flickwise" ] || die "The build didn't produce an app."

# ── 4. Install ───────────────────────────────────────────────────────────────
step "Installing into $APPS_DIR"
mkdir -p "$APPS_DIR"
DEST="$APPS_DIR/Flickwise.app"
if pgrep -f "$DEST/Contents/MacOS/Flickwise" >/dev/null 2>&1 || pgrep -x Flickwise >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Flickwise >/dev/null 2>&1 || break; sleep 0.3; done
    pkill -x Flickwise 2>/dev/null || true
    ok "Stopped the running copy"
fi
if [ -d "$DEST" ]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing" != "$BUNDLE_ID" ]; then
        # The Hammerspoon version's Spotlight launcher: replaced by the real app.
        info "Replacing the old Hammerspoon launcher ($existing)"
    fi
    rm -rf "$DEST"
fi
ditto "$BUILT" "$DEST"
ok "Installed $DEST"

# ── 5. Speech model ──────────────────────────────────────────────────────────
if [ "${FLICKWISE_SKIP_MODEL:-}" != "1" ]; then
    step "Speech model (runs on this Mac)"
    # The app owns the model catalog: ask it for the file, URL, checksum and destination.
    if INFO="$("$DEST/Contents/MacOS/Flickwise" --model-info "${FLICKWISE_MODEL:-large-v3-turbo-q8_0}")"; then
        read -r M_FILE M_URL M_SHA M_BYTES _ <<< "$INFO"
        M_PATH="${INFO#* * * * }"
        if [ -f "$M_PATH" ]; then
            ok "$M_FILE already downloaded"
        else
            mkdir -p "$(dirname "$M_PATH")"
            info "Downloading $M_FILE ($((M_BYTES / 1000000)) MB) — this happens once"
            if curl -fL --retry 3 -C - --progress-bar -o "$M_PATH.part" "$M_URL" \
               && echo "$M_SHA  $M_PATH.part" | shasum -a 256 -c - >/dev/null 2>&1; then
                mv "$M_PATH.part" "$M_PATH"
                ok "Downloaded and verified $M_FILE"
            else
                rm -f "$M_PATH.part"
                warn "The model download failed. Open Flickwise → Settings → Speech recognition to download it."
            fi
        fi
    else
        warn "Unknown speech model '${FLICKWISE_MODEL:-}'. Skipping the download."
    fi
    if [ "${FLICKWISE_NEURAL_ENGINE:-}" = "1" ] \
       && C_INFO="$("$DEST/Contents/MacOS/Flickwise" --coreml-info "${FLICKWISE_MODEL:-large-v3-turbo-q8_0}")"; then
        read -r C_NAME C_URL C_SHA C_BYTES _ <<< "$C_INFO"
        C_PATH="${C_INFO#* * * * }"
        if [ -d "$C_PATH" ]; then
            ok "Neural Engine encoder already downloaded"
        else
            info "Downloading the Neural Engine encoder ($((C_BYTES / 1000000)) MB)"
            C_ZIP="$C_PATH.zip.part"
            if curl -fL --retry 3 -C - --progress-bar -o "$C_ZIP" "$C_URL" \
               && echo "$C_SHA  $C_ZIP" | shasum -a 256 -c - >/dev/null 2>&1; then
                C_TMP="$(mktemp -d)"
                ditto -x -k "$C_ZIP" "$C_TMP" && mv "$C_TMP/$C_NAME" "$C_PATH" \
                    && ok "Neural Engine encoder ready (the first launch prepares it, ~2 min, once)" \
                    || warn "Couldn't unpack the Neural Engine encoder."
                rm -rf "$C_TMP" "$C_ZIP"
            else
                rm -f "$C_ZIP"
                warn "The Neural Engine encoder download failed. You can get it later in Settings."
            fi
        fi
    fi
fi

# ── 6. Hand dictation over from Hammerspoon ──────────────────────────────────
HS_CONFIG="$HS_DIR/flickwise/config.yaml"
if [ "${FLICKWISE_KEEP_HS_DICTATION:-}" != "1" ] && [ -f "$HS_CONFIG" ]; then
    # Flip `enabled: true` → false only inside the `  dictation:` block under features:.
    if awk '/^  dictation:/{b=1;next} b&&/^  [^ ]/{b=0} b&&/^    enabled:[[:space:]]*true/{f=1} END{exit !f}' "$HS_CONFIG"; then
        cp "$HS_CONFIG" "$HS_CONFIG.backup.$STAMP"
        awk '/^  dictation:/{b=1;print;next} b&&/^  [^ ]/{b=0}
             b&&/^    enabled:[[:space:]]*true/{sub(/enabled:[[:space:]]*true/,"enabled: false")} {print}' \
            "$HS_CONFIG.backup.$STAMP" > "$HS_CONFIG"
        ok "Turned off dictation in the Hammerspoon version (the native app handles it now)"
        info "Backup: $HS_CONFIG.backup.$STAMP"
    fi
fi

# ── 7. Launch ────────────────────────────────────────────────────────────────
if [ "${FLICKWISE_NO_LAUNCH:-}" != "1" ]; then
    open "$DEST"
    ok "Flickwise is running (look for the waveform in the menu bar)"
fi

echo
echo "${G}${B}Done.${X}"
echo "  First time on this Mac? The setup window walks you through:"
echo "   • Accessibility (to notice the key and type for you)"
echo "   • Microphone"
echo "  Speech is recognized on this Mac (no API key needed). Gemini is optional, in Settings."
echo "  Then hold the dictation key (Right ⌘ by default), speak, and let go."
echo "  To update later, run this installer again."
echo
