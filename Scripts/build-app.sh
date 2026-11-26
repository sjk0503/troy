#!/usr/bin/env bash
# Builds Troy in release mode and assembles an ad-hoc signed build/Troy.app.
#
# Environment:
#   SCRATCH_PATH  optional SwiftPM scratch path (passed as --scratch-path)
#   BUNDLE_ID     bundle identifier, default dev.troy.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="${BUNDLE_ID:-dev.troy.app}"
VERSION="$(tr -d '[:space:]' < VERSION)"
if BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)" && [ -n "$BUILD_NUMBER" ]; then
    :
else
    BUILD_NUMBER=1
fi

SWIFT_ARGS=(-c release)
if [ -n "${SCRATCH_PATH:-}" ]; then
    SWIFT_ARGS+=(--scratch-path "$SCRATCH_PATH")
fi

echo "==> Building TroyApp and troy (release)"
swift build "${SWIFT_ARGS[@]}" --product TroyApp
swift build "${SWIFT_ARGS[@]}" --product troy
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

APP="$ROOT/build/Troy.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/TroyApp" "$APP/Contents/MacOS/Troy"
cp "$BIN_DIR/troy" "$APP/Contents/Helpers/troy"
cp "$ROOT/Resources/Troy.icns" "$APP/Contents/Resources/Troy.icns"
cp "$ROOT/docs/Troy-Guide-ko.pdf" "$APP/Contents/Resources/Troy-Guide-ko.pdf"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Troy</string>
    <key>CFBundleDisplayName</key>
    <string>Troy</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>Troy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>Troy</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Seongjae and the Troy contributors. MIT License.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>troy</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad hoc)"
SIGN_FLAGS=(--force --sign - --timestamp=none --options runtime)
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/troy"
codesign "${SIGN_FLAGS[@]}" "$APP"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "codesign: OK (ad hoc, $BUNDLE_ID $VERSION build $BUILD_NUMBER)"
else
    echo "codesign: verification FAILED" >&2
    codesign --verify --deep --strict --verbose=2 "$APP" >&2 || true
    exit 1
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "==> Done: $APP ($SIZE)"
