#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="$ROOT/.build/Ollama Screen Overlay.app"
BIN="$APP/Contents/MacOS/OllamaScreenOverlay"
SOURCE="$ROOT/OllamaScreenOverlay.swift"

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'This implementation requires macOS 14 or newer.' >&2
    exit 1
fi
OS_VERSION="$(sw_vers -productVersion)"
if (( ${OS_VERSION%%.*} < 14 )); then
    echo 'This implementation requires macOS 14 or newer.' >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'Install Apple Command Line Tools with: xcode-select --install' >&2
    exit 1
fi

if [[ ! -x "$BIN" || "$SOURCE" -nt "$BIN" || "$0" -nt "$BIN" ]]; then
    mkdir -p "$APP/Contents/MacOS" "$ROOT/.build/module-cache"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OllamaScreenOverlay</string>
  <key>CFBundleIdentifier</key><string>local.ollama.screen-overlay</string>
  <key>CFBundleName</key><string>Ollama Screen Overlay</string>
  <key>CFBundleDisplayName</key><string>Ollama Screen Overlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    echo 'Building the native macOS overlay…'
    xcrun swiftc -parse-as-library -swift-version 5 -O \
        -target "$(uname -m)-apple-macosx14.0" \
        -module-cache-path "$ROOT/.build/module-cache" \
        -framework AppKit -framework ImageIO \
        "$SOURCE" -o "$BIN"
    codesign --force --sign - "$APP"
fi

if [[ "${1:-}" == --build-only ]]; then
    echo "$APP"
else
    # Validate options in the terminal before starting an otherwise silent GUI app.
    MODE="$("$BIN" --launch-mode "$@")"
    if [[ "$MODE" == cli ]]; then
        exec "$BIN" "$@"
    else
        # -W waits for dismissal; -g avoids taking keyboard focus.
        open -g -n -W "$APP" --args "$@"
    fi
fi
