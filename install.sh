#!/usr/bin/env bash
# Flickwise installer / updater: safe to run again at any time.
#
#   curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/install.sh | bash
#
# What it does:
#   1. Checks macOS, git, and Hammerspoon (installs Hammerspoon with Homebrew if needed)
#   2. Clones Flickwise into ~/.hammerspoon/flickwise, or updates an existing clone
#   3. Migrates an old TextFixer install (keeps its config and API key, backs it up)
#   4. Creates config.yaml from the template if missing, and adds new `features:` settings to an old one
#   5. Adds `require("flickwise")` to ~/.hammerspoon/init.lua
#   6. Creates ~/Applications/Flickwise.app (Spotlight launcher) and reloads Hammerspoon
#
# Environment overrides (mostly for testing):
#   FLICKWISE_REPO     git URL      (default: https://github.com/shahraizanwer/flickwise.git)
#   FLICKWISE_BRANCH   branch       (default: main)
#   FLICKWISE_HS_DIR   Hammerspoon config dir (default: ~/.hammerspoon)
#   FLICKWISE_APPS_DIR launcher dir (default: ~/Applications)
#   FLICKWISE_SKIP_HAMMERSPOON=1    don't check for, install, or reload Hammerspoon

set -euo pipefail

REPO="${FLICKWISE_REPO:-https://github.com/shahraizanwer/flickwise.git}"
BRANCH="${FLICKWISE_BRANCH:-main}"
HS_DIR="${FLICKWISE_HS_DIR:-$HOME/.hammerspoon}"
APPS_DIR="${FLICKWISE_APPS_DIR:-$HOME/Applications}"
DEST="$HS_DIR/flickwise"
OLD="$HS_DIR/textfixer"
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
echo "${B}Flickwise installer${X}"

# ── 1. Requirements ──────────────────────────────────────────────────────────
step "Checking requirements"
[ "$(uname -s)" = "Darwin" ] || die "Flickwise runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 12 ] || die "macOS 12 or later is required (you have $(sw_vers -productVersion))."
ok "macOS $(sw_vers -productVersion)"

if ! git --version >/dev/null 2>&1; then
    die "git is missing. Run:  xcode-select --install   then run this installer again."
fi
ok "git"

hs_app() {
    for p in "/Applications/Hammerspoon.app" "$HOME/Applications/Hammerspoon.app"; do
        [ -d "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

if [ "${FLICKWISE_SKIP_HAMMERSPOON:-}" != "1" ]; then
    if HS_APP="$(hs_app)"; then
        ok "Hammerspoon ($HS_APP)"
    elif command -v brew >/dev/null 2>&1; then
        info "Installing Hammerspoon with Homebrew…"
        brew install --cask hammerspoon
        HS_APP="$(hs_app)" || die "Hammerspoon install failed."
        ok "Hammerspoon installed"
    else
        echo
        warn "Hammerspoon is required (free, open source)."
        echo "    Download it from https://www.hammerspoon.org, move it to Applications,"
        echo "    open it once, then run this installer again."
        open "https://www.hammerspoon.org" 2>/dev/null || true
        exit 1
    fi
fi

# ── 2. Get or update the code ────────────────────────────────────────────────
step "Installing Flickwise into $DEST"
mkdir -p "$HS_DIR"

if [ -d "$DEST/.git" ]; then
    if [ -n "$(git -C "$DEST" status --porcelain --untracked-files=no)" ]; then
        warn "You have local code changes in $DEST, so it wasn't updated (config.yaml is fine)."
        info "Commit or stash them, then run: git -C \"$DEST\" pull"
    else
        git -C "$DEST" pull --ff-only --quiet origin "$BRANCH" && ok "Updated to the latest version" \
            || warn "Couldn't update (offline or diverged). Keeping the current version."
    fi
else
    SAVED_CONFIG=""
    if [ -d "$DEST" ]; then
        # An older copy that isn't a git clone: back it up and keep its config.
        mv "$DEST" "$DEST.backup.$STAMP"
        warn "Moved the old non-git copy to $(basename "$DEST").backup.$STAMP"
        [ -f "$DEST.backup.$STAMP/config.yaml" ] && SAVED_CONFIG="$DEST.backup.$STAMP/config.yaml"
    fi
    git clone --quiet --branch "$BRANCH" "$REPO" "$DEST" || die "git clone failed: $REPO"
    ok "Cloned $REPO"
    if [ -n "$SAVED_CONFIG" ]; then
        cp "$SAVED_CONFIG" "$DEST/config.yaml"
        ok "Kept your existing config.yaml"
    fi
fi

# ── 3. Migrate an old TextFixer install ──────────────────────────────────────
INIT="$HS_DIR/init.lua"
if [ -d "$OLD" ]; then
    step "Upgrading from TextFixer"
    if [ ! -f "$DEST/config.yaml" ] && [ -f "$OLD/config.yaml" ]; then
        cp "$OLD/config.yaml" "$DEST/config.yaml"
        ok "Copied your TextFixer config (modes, hotkeys, API key)"
    fi
    OLD_BACKUP="$HS_DIR/textfixer.backup.$STAMP"
    mv "$OLD" "$OLD_BACKUP"
    ok "Backed up TextFixer to $(basename "$OLD_BACKUP")"
    if [ -d "$APPS_DIR/TextFixer.app" ]; then
        mv "$APPS_DIR/TextFixer.app" "$OLD_BACKUP/"
        ok "Moved TextFixer.app into the backup"
    fi
fi
if [ -f "$INIT" ] && grep -Eq "require[ (]*[\"']textfixer[\"']" "$INIT"; then
    cp "$INIT" "$INIT.backup.$STAMP"
    sed -E -i '' "/require[ (]*[\"']textfixer[\"']/d" "$INIT"
    ok "Removed require(\"textfixer\") from init.lua"
fi

# ── 4. Config ────────────────────────────────────────────────────────────────
step "Config"
CONFIG="$DEST/config.yaml"
EXAMPLE="$DEST/config.example.yaml"
if [ ! -f "$CONFIG" ]; then
    cp "$EXAMPLE" "$CONFIG"
    ok "Created config.yaml from the template"
elif ! grep -q "^features:" "$CONFIG"; then
    # Older config: add the documented features block (above `modes:`) so the
    # new settings are visible. Defaults apply either way.
    cp "$CONFIG" "$CONFIG.backup.$STAMP"
    awk -v ex="$EXAMPLE" '
        BEGIN {
            while ((getline line < ex) > 0) {
                if (line ~ /^# ── Features/) grab = 1
                if (line ~ /^modes:/) grab = 0
                if (grab) block = block line "\n"
            }
        }
        /^modes:/ && !done { printf "%s", block; done = 1 }
        { print }
    ' "$CONFIG.backup.$STAMP" > "$CONFIG"
    ok "Added the new features: section to your config.yaml (old one backed up)"
else
    ok "config.yaml kept as is"
fi

# ── 5. Hammerspoon init.lua ──────────────────────────────────────────────────
step "Hammerspoon setup"
touch "$INIT"
if ! grep -q "hs.ipc.cliInstall" "$INIT"; then
    tmp="$(mktemp)"; { echo 'hs.ipc.cliInstall()'; cat "$INIT"; } > "$tmp"; mv "$tmp" "$INIT"
    ok "Enabled the hs command-line tool"
fi
if grep -Eq "require[ (]*[\"']flickwise[\"']" "$INIT"; then
    ok "init.lua already loads Flickwise"
else
    printf '\nrequire("flickwise")\n' >> "$INIT"
    ok "Added require(\"flickwise\") to init.lua"
fi

# ── 6. Spotlight launcher ────────────────────────────────────────────────────
APP="$APPS_DIR/Flickwise.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Flickwise</string>
  <key>CFBundleIdentifier</key><string>com.flickwise.launcher</string>
  <key>CFBundleExecutable</key><string>Flickwise</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
printf '#!/bin/bash\nopen "hammerspoon://flickwise-open"\n' > "$APP/Contents/MacOS/Flickwise"
chmod +x "$APP/Contents/MacOS/Flickwise"
ICON_PNG="$DEST/assets/flickwise-icon-1024.png"
if [ -f "$ICON_PNG" ] && [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    iconset="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$iconset"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$ICON_PNG" --out "$iconset/icon_${s}x${s}.png" >/dev/null 2>&1 || true
        sips -z $((s*2)) $((s*2)) "$ICON_PNG" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi
ok "Flickwise.app in $(basename "$APPS_DIR") (search \"Flickwise\" in Spotlight to open settings)"

# ── 7. Reload Hammerspoon ────────────────────────────────────────────────────
if [ "${FLICKWISE_SKIP_HAMMERSPOON:-}" != "1" ]; then
    step "Starting Flickwise"
    if pgrep -x Hammerspoon >/dev/null; then
        if command -v hs >/dev/null 2>&1 && perl -e 'alarm 5; exec @ARGV' hs -c 'hs.reload()' >/dev/null 2>&1; then
            ok "Hammerspoon reloaded"
        else
            osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
            sleep 1
            open -a Hammerspoon
            ok "Hammerspoon restarted"
        fi
    else
        open -a Hammerspoon
        ok "Hammerspoon launched"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo
echo "${G}${B}Flickwise is installed.${X}"
echo
echo "  First time on this Mac?"
echo "   • Allow Hammerspoon in System Settings → Privacy & Security → Accessibility"
if grep -Eq '^gemini_api_key: *""' "$CONFIG" && grep -Eq '^glean_binary_path: *""' "$CONFIG"; then
    echo "   • Add a Gemini API key: a setup window opens automatically"
    echo "     (free key: https://aistudio.google.com/app/apikey)"
fi
echo
echo "  Try it: select text anywhere, then"
echo "   • ⌘⇧G  Fix Grammar       • ⌘⇧P  pick from all modes"
echo "   • hold Right ⌥, flick toward a mode, release"
echo
echo "  Update later by running the same command again."
echo
