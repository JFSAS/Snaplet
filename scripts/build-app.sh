#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
CONFIGURATION="${1:-debug}"
SIGNING_IDENTITY="${SNAPLET_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$PROJECT_ROOT/.signing-identity" ]; then
    IFS= read -r SIGNING_IDENTITY < "$PROJECT_ROOT/.signing-identity"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;;
esac

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_PATH="$PROJECT_ROOT/build/$CONFIGURATION/Snaplet.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/Snaplet" "$APP_PATH/Contents/MacOS/Snaplet"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"
codesign --verify --strict "$APP_PATH"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Note: ad-hoc signing binds permissions to this build. Configure a development identity to retain permissions across builds."
fi
echo "Built: $APP_PATH"
