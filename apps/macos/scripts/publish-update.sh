#!/usr/bin/env bash
#
# Publishes a release DMG as an update: signs it into the Sparkle feed with
# the update key in this Mac's keychain (account dogecoinvm-wallet), and
# uploads the feed and DMGs to the download server. Installed apps find it on
# their next daily check, and verify the signature before installing.
#
#   ./scripts/publish-update.sh build/release/DogecoinVM-Wallet-0.1.0.dmg
#
# Only publish notarized DMGs. Back up the update key once, somewhere safe:
#   <Sparkle bin>/generate_keys --account dogecoinvm-wallet -x update-key.txt
# Without it, installed apps can never be updated.
set -euo pipefail
cd "$(dirname "$0")/.."                              # apps/macos

DMG="${1:?usage: $0 path/to/DogecoinVM-Wallet-X.Y.Z.dmg}"
HOST="${DEPLOY_HOST:-root@46.224.68.52}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pulsevm_dev}"
REMOTE_DIR=/var/www/metaldoge-downloads/macos
URL_PREFIX=https://metaldoge.com/download/macos/
UPDATES=build/updates
SPARKLE_BIN=$(find build -path '*artifacts/sparkle/Sparkle/bin' -type d | head -1)
[ -n "$SPARKLE_BIN" ] || { echo "Sparkle tools not found; build the app once first" >&2; exit 1; }

xcrun stapler validate "$DMG" >/dev/null 2>&1 || {
    echo "$DMG is not notarized. Publish only notarized builds." >&2; exit 1; }

mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
echo "▶︎ Signing the update feed…"
"$SPARKLE_BIN/generate_appcast" --account dogecoinvm-wallet --download-url-prefix "$URL_PREFIX" "$UPDATES"

echo "▶︎ Uploading…"
ssh -i "$SSH_KEY" "$HOST" "mkdir -p $REMOTE_DIR"
rsync -a -e "ssh -i $SSH_KEY" "$UPDATES/appcast.xml" "$UPDATES/"*.dmg "$HOST:$REMOTE_DIR/"
# A stable link to the newest version, and its checksum for the download page.
ssh -i "$SSH_KEY" "$HOST" "cp $REMOTE_DIR/$(basename "$DMG") $REMOTE_DIR/DogecoinVM-Wallet.dmg"
shasum -a 256 "$DMG" | awk '{print $1 "  DogecoinVM-Wallet.dmg"}' | ssh -i "$SSH_KEY" "$HOST" "cat > $REMOTE_DIR/DogecoinVM-Wallet.dmg.sha256"
echo "✅ Published: ${URL_PREFIX}DogecoinVM-Wallet.dmg (feed: ${URL_PREFIX}appcast.xml)"
