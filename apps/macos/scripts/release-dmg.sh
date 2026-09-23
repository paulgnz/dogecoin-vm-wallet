#!/usr/bin/env bash
#
# Builds a signed, notarized "DogecoinVM Wallet.dmg" that opens cleanly on any
# Mac, for download outside the App Store.
#
# One-time setup, storing notarization credentials in the keychain:
#   xcrun notarytool store-credentials "pulsevm-notary" \
#       --apple-id "you@example.com" --team-id "UKU2H2D5Z7" \
#       --password "app-specific-password"   # from appleid.apple.com
#
# Then:  ./scripts/release-dmg.sh               (signed and notarized)
#        ./scripts/release-dmg.sh --no-notarize (signed only: recipients
#        right-click, Open the first time)
set -euo pipefail
cd "$(dirname "$0")/.."                              # apps/macos

NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

APP_NAME="DogecoinVM Wallet"
SCHEME="DogecoinVMWallet"
TEAM="${TEAM_ID:-UKU2H2D5Z7}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pulsevm-notary}"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMG="$BUILD_DIR/DogecoinVM-Wallet-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"

echo "▶︎ Building the Rust core (universal)…"
../../scripts/build-core-macos.sh >/dev/null

echo "▶︎ Generating the project…"
xcodegen generate >/dev/null

BUILD_NO=$(git rev-list --count HEAD 2>/dev/null || echo 1)
echo "▶︎ Archiving $VERSION (build $BUILD_NO)…"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project DogecoinVMWallet.xcodeproj -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR/dd" archive \
    DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD_NO" -quiet

echo "▶︎ Exporting with Developer ID…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR" -quiet

APP="$EXPORT_DIR/$APP_NAME.app"
echo "▶︎ Verifying the signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶︎ Building the DMG…"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [ "$NOTARIZE" = "1" ]; then
    echo "▶︎ Notarizing (a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

rm -rf "$STAGE" "$EXPORT_DIR" "$ARCHIVE" "$BUILD_DIR/dd"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✅ $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
[ "$NOTARIZE" = "1" ] || echo "   Not notarized: recipients right-click the app and choose Open the first time."
