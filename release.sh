#!/bin/bash
# Builds the .app and packages a DMG for distribution.
# Requires `dmgbuild` (pipx install dmgbuild, or: python3 -m pip install
# dmgbuild) — it writes the styled installer window's .DS_Store directly,
# no Finder scripting, so it runs headless on CI. Unsigned — no Apple
# Developer Program certificates involved. Ad-hoc codesign keeps Apple
# Silicon Macs from rejecting the binary as "damaged" after re-download.
#
# Update flow: after the DMG is built, sign it with the Sparkle EdDSA key
# and generate dist/appcast.xml. CI uploads the DMG and appcast as GitHub
# Release assets; Sparkle clients fetch the latest appcast from the release.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be X.Y.Z (got '$VERSION')" >&2
  exit 1
fi
APP_NAME="Gauge"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/Gauge-$VERSION.dmg"

DMGBUILD="dmgbuild"
if ! command -v dmgbuild >/dev/null 2>&1; then
  if python3 -c "import dmgbuild" >/dev/null 2>&1; then
    DMGBUILD="python3 -m dmgbuild"
  else
    echo "error: dmgbuild is required. Install with: pipx install dmgbuild (or: python3 -m pip install dmgbuild)" >&2
    exit 1
  fi
fi

# Release builds carry the live Sparkle feed; dev builds default to none
# (a dev instance once self-updated and trashed its own bundle).
SU_FEED_URL="https://github.com/tristan666666/agent-island/releases/latest/download/appcast.xml" ./build.sh

rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "build/$APP_NAME.app" "$DIST/"

# Ad-hoc sign — does NOT satisfy Gatekeeper, but prevents the
# "AgentIsland is damaged and can't be opened" failure mode that
# unsigned Apple Silicon binaries hit after a download round-trip.
codesign --force --deep --sign - "$APP"

# Styled installer window: dark backdrop + wordmark + drag arrow (the bare
# create-dmg window read as a debug artifact next to polished installers).
# 1x/2x PNGs combine into a retina-aware TIFF Finder picks per display.
tiffutil -cathidpicheck packaging/dmg/background.png packaging/dmg/background@2x.png \
  -out "$DIST/dmg-background.tiff" >/dev/null

rm -f "$DMG"
$DMGBUILD \
  -s packaging/dmg/settings.py \
  -D app="$APP" \
  -D background="$DIST/dmg-background.tiff" \
  -D icon="Resources/AgentIsland.icns" \
  "Agent Island $VERSION" \
  "$DMG"

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
DMG_SIZE_BYTES="$(stat -f%z "$DMG")"

# Sign the DMG with Sparkle's EdDSA key, then write appcast.xml as a release
# asset. Two ways to provide the key:
#   - Local: stored in Keychain by `Vendor/Sparkle/bin/generate_keys` (default)
#   - CI:    file path in $SPARKLE_PRIVATE_KEY_PATH (passed via GitHub Secret)
SIGN_TOOL="Vendor/Sparkle/bin/sign_update"
APPCAST="$DIST/appcast.xml"

have_key=0
sign_args=()
if [[ -n "${SPARKLE_PRIVATE_KEY_PATH:-}" && -f "${SPARKLE_PRIVATE_KEY_PATH}" ]]; then
  sign_args+=(--ed-key-file "${SPARKLE_PRIVATE_KEY_PATH}")
  have_key=1
elif security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
  have_key=1
fi

if [[ -x "$SIGN_TOOL" && $have_key -eq 1 ]]; then
  SIG_LINE="$("$SIGN_TOOL" ${sign_args[@]+"${sign_args[@]}"} "$DMG")"
  EDSIG="$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"

  # set -euo pipefail only catches non-zero exits; sign_update can exit 0 with
  # malformed output, which would ship an appcast Sparkle clients reject silently.
  if [[ -z "${EDSIG:-}" ]]; then
    echo "error: sign_update produced empty EdDSA signature; aborting release" >&2
    echo "  raw output: $SIG_LINE" >&2
    exit 1
  fi

  RELEASE_URL="https://github.com/tristan666666/agent-island/releases/download/v${VERSION}/$(basename "$DMG")"
  PUBDATE="$(LC_TIME=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")"

  cat > "$APPCAST" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>AgentIsland</title>
    <link>https://github.com/tristan666666/agent-island/releases/latest/download/appcast.xml</link>
    <description>Most recent AgentIsland release.</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/tristan666666/agent-island/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure url="$RELEASE_URL" sparkle:version="$VERSION" sparkle:shortVersionString="$VERSION" length="$DMG_SIZE_BYTES" type="application/octet-stream" sparkle:edSignature="$EDSIG" />
    </item>
  </channel>
</rss>
EOF

  echo "✓ $APPCAST signed and ready to publish"
else
  echo "⚠ skipping appcast — sign_update missing or no signing key (see docs/SPARKLE.md)"
fi

echo ""
echo "✓ $DMG"
echo "  size: $(du -h "$DMG" | cut -f1)"
echo "  sha256: $DMG_SHA256"
