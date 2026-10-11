#!/usr/bin/env bash
# Builds Flickwise.app from source into macos/build/ using swiftc directly
# (only the Xcode Command Line Tools are needed; no Xcode, no SwiftPM).
#   scripts/build.sh            optimized build
#   scripts/build.sh debug      faster compile, debug checks on
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # .../macos
REPO="$(cd "$ROOT/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Flickwise.app"
MODE="${1:-release}"
ARCH="$(uname -m)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_OS="13.3"                                       # whisper.framework needs 13.3

# whisper.cpp (local speech recognition): official prebuilt framework, pinned and checksum-verified.
WHISPER_TAG="b5130"                                 # = whisper.cpp v1.9.4
WHISPER_SHA256="033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
VENDOR="$ROOT/vendor"                               # git-ignored download cache

VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
BUILD="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "→ Compiling Flickwise $VERSION ($BUILD) for $ARCH, $MODE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

WHISPER_DIR="$VENDOR/whisper-$WHISPER_TAG"
if [ ! -d "$WHISPER_DIR/whisper.framework" ]; then
    echo "→ Downloading whisper.cpp $WHISPER_TAG framework (once)"
    TMP="$(mktemp -d)"
    curl -fsSL -o "$TMP/whisper.zip" \
        "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_TAG/whisper-$WHISPER_TAG-xcframework.zip"
    echo "$WHISPER_SHA256  $TMP/whisper.zip" | shasum -a 256 -c - >/dev/null \
        || { echo "✗ whisper.cpp download failed its checksum" >&2; rm -rf "$TMP"; exit 1; }
    unzip -q "$TMP/whisper.zip" -d "$TMP"
    mkdir -p "$WHISPER_DIR"
    ditto "$TMP/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework" "$WHISPER_DIR/whisper.framework"
    rm -rf "$TMP"
fi

FLAGS=(-O -whole-module-optimization)
[ "$MODE" = "debug" ] && FLAGS=(-Onone -g -DDEBUG)

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)

# Older Command Line Tools upgrades can leave a stale usr/include/swift/module.modulemap that
# redefines SwiftBridging and breaks every import. Hide it with a VFS overlay (no sudo needed).
TOOLCHAIN_INC="$(dirname "$(xcrun --find swiftc)")/../include/swift"
if [ -f "$TOOLCHAIN_INC/module.modulemap" ] && [ -f "$TOOLCHAIN_INC/bridging.modulemap" ]; then
    mkdir -p "$OUT"
    STALE="$(cd "$TOOLCHAIN_INC" && pwd)/module.modulemap"
    : > "$OUT/empty.modulemap"
    cat > "$OUT/toolchain-overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "file", "name": "$STALE", "external-contents": "$OUT/empty.modulemap" } ] }
YAML
    FLAGS+=(-vfsoverlay "$OUT/toolchain-overlay.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/toolchain-overlay.yaml")
fi

swiftc "${FLAGS[@]}" \
    -swift-version 5 \
    -target "$ARCH-apple-macos$MIN_OS" \
    -sdk "$SDK" \
    -module-name Flickwise \
    -lsqlite3 \
    -F "$WHISPER_DIR" -framework whisper \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/Flickwise" \
    "${SOURCES[@]}"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
mkdir -p "$APP/Contents/Frameworks"
ditto "$WHISPER_DIR/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"

# App icon from the repo's 1024 px PNG (cached between builds).
ICON_SRC="$REPO/assets/flickwise-icon-1024.png"
ICNS="$OUT/AppIcon.icns"
if [ -f "$ICON_SRC" ] && { [ ! -f "$ICNS" ] || [ "$ICON_SRC" -nt "$ICNS" ]; }; then
    SET="$OUT/AppIcon.iconset"
    rm -rf "$SET"; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$ICNS"
    rm -rf "$SET"
fi
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Sign with the stable local identity so macOS remembers permissions across rebuilds.
IDENTITY="Flickwise Local Signing"
if KC="$("$ROOT/scripts/signing-identity.sh" 2>/dev/null)" \
   && codesign --force --sign "$IDENTITY" --keychain "$KC" --timestamp=none "$APP/Contents/Frameworks/whisper.framework" 2>/dev/null \
   && codesign --force --sign "$IDENTITY" --keychain "$KC" --timestamp=none "$APP" 2>/dev/null; then
    echo "→ Signed with \"$IDENTITY\""
else
    codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
    codesign --force --sign - "$APP"
    echo "→ Signed ad-hoc (macOS may ask for permissions again after each rebuild)"
fi
echo "✓ Built $APP"
