#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$ROOT/.build/module-cache"
xcrun swiftc -parse-as-library -swift-version 5 -D TESTING \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$ROOT/.build/module-cache" \
    -framework AppKit -framework ImageIO \
    "$ROOT/OllamaScreenOverlay.swift" "$ROOT/Tests.swift" -o "$ROOT/.build/tests"
"$ROOT/.build/tests" "$@"
