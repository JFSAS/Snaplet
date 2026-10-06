#!/bin/bash
# Regression check: two different binaries must satisfy the same development identity.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_IDENTITY="${SNAPLET_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$PROJECT_ROOT/.signing-identity" ]; then
    IFS= read -r SIGNING_IDENTITY < "$PROJECT_ROOT/.signing-identity"
fi
if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "This check requires a configured development signing identity." >&2
    exit 1
fi
mkdir -p "$PROJECT_ROOT/work"
FIXTURE_ROOT="$(mktemp -d "$PROJECT_ROOT/work/signing.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
for VARIANT in first second; do
    APP_PATH="$FIXTURE_ROOT/$VARIANT/Snaplet.app"
    mkdir -p "$APP_PATH/Contents/MacOS"
    cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
    printf 'print("%s")\n' "$VARIANT" > "$FIXTURE_ROOT/$VARIANT.swift"
    swiftc "$FIXTURE_ROOT/$VARIANT.swift" -o "$APP_PATH/Contents/MacOS/Snaplet"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"
    codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^designated => //p' > "$FIXTURE_ROOT/$VARIANT.requirement"
    codesign -d --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^CDHash=//p' > "$FIXTURE_ROOT/$VARIANT.hash"
    test -s "$FIXTURE_ROOT/$VARIANT.hash"
done
cmp "$FIXTURE_ROOT/first.requirement" "$FIXTURE_ROOT/second.requirement"
if cmp -s "$FIXTURE_ROOT/first.hash" "$FIXTURE_ROOT/second.hash"; then
    echo "Fixture binaries unexpectedly have identical hashes." >&2
    exit 1
fi
REQUIREMENT="$(cat "$FIXTURE_ROOT/first.requirement")"
codesign --verify --strict -R "=$REQUIREMENT" "$FIXTURE_ROOT/second/Snaplet.app"
echo "PASS: changed executable hash retains the same verified development identity."
