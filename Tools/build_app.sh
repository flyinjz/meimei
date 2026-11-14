#!/bin/bash
# Builds the Swift package in release mode and assembles a real, native,
# double-clickable i2s.app bundle (no Electron/webview — this just packages
# the compiled Mach-O binary produced by `swift build`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="i2s"
BUNDLE_ID="com.meimei.player"
BUILD_CONFIG="${1:-release}"

cd "$ROOT_DIR"
echo "==> Building Raven Tunnel (Go)…"
mkdir -p "$ROOT_DIR/.build-tunnel"
(cd "$ROOT_DIR/RavenTunnel" && CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 MACOSX_DEPLOYMENT_TARGET=13.0 \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "$ROOT_DIR/.build-tunnel/libraventunnel.a" .)
echo "==> Building ($BUILD_CONFIG)…"
swift build -c "$BUILD_CONFIG"

BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/MeimeiPlayer"
if [ ! -f "$BIN_PATH" ]; then
    echo "Build product not found at $BIN_PATH" >&2
    exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH" "$CONTENTS/MacOS/MeimeiPlayer"
chmod +x "$CONTENTS/MacOS/MeimeiPlayer"
cp "$ROOT_DIR/Distribution/Info.plist" "$CONTENTS/Info.plist"

# Bundled typefaces (subset Nerd Fonts) and their licenses.
mkdir -p "$CONTENTS/Resources/Fonts/Licenses"
cp "$ROOT_DIR"/Assets/Fonts/*.* "$CONTENTS/Resources/Fonts/"
cp "$ROOT_DIR"/Assets/Fonts/Licenses/* "$CONTENTS/Resources/Fonts/Licenses/"

if [ -f "$ROOT_DIR/Distribution/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Distribution/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Ad-hoc code sign so macOS Gatekeeper / TCC (mic, file access prompts) behave
# consistently across relaunches during development.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Done: $APP_BUNDLE"
echo "    Run with: open \"$APP_BUNDLE\""
