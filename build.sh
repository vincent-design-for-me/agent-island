#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Gauge"
BUNDLE_ID="dev.agentisland.AgentIsland"
VERSION="$(cat VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be X.Y.Z (got '$VERSION')" >&2
  exit 1
fi
BUILD_DIR="./build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"

# Sparkle framework is vendored under Vendor/Sparkle. The setup script is a
# no-op once it's in place, so it's safe to run on every build.
./scripts/setup-sparkle.sh
SPARKLE_DIR="Vendor/Sparkle"
SPARKLE_FW="$SPARKLE_DIR/Sparkle.framework"

# Public EdDSA key embedded in Info.plist as SUPublicEDKey. The PUBLIC half
# of the keypair is safe to commit — it's meant to ship inside distributed
# apps so Sparkle can verify update signatures. The matching PRIVATE key is
# in the maintainer's Keychain (and the SPARKLE_ED_PRIVATE_KEY GitHub Secret
# for CI). To rotate, see docs/SPARKLE.md — DO NOT change this lightly:
# every existing install verifies updates against this exact public key, and
# changing it strands them.
SU_PUBLIC_KEY="6WJHeBVv3Ft3hRGnmsSEQ8T7AW8jurRQiBfTPtJ5gK0="

# Default EMPTY for local/dev builds: a dev instance with a live feed will
# Sparkle-update ITSELF the moment a new release ships — it trashes its own
# bundle out of the build dir and leaves a ghost process with no resources
# (2026-07-14 incident). The release workflow passes the real feed URL.
SU_FEED_URL="${SU_FEED_URL:-}"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR"

cp ./Resources/claude_logo.pdf "$RES_DIR/claude_logo.pdf"
cp ./Resources/openai_logo.pdf "$RES_DIR/openai_logo.pdf"
cp ./Resources/cursor_logo.pdf "$RES_DIR/cursor_logo.pdf"
cp ./Resources/grok_logo.pdf "$RES_DIR/grok_logo.pdf"
cp ./Resources/gemini_logo.pdf "$RES_DIR/gemini_logo.pdf"
cp ./Resources/duel-claude-wins.png "$RES_DIR/duel-claude-wins.png"
cp ./Resources/duel-codex-wins.png "$RES_DIR/duel-codex-wins.png"
cp ./Resources/duel-draw.png "$RES_DIR/duel-draw.png"
cp ./Resources/gauge_logo.png "$RES_DIR/gauge_logo.png"
cp ./Resources/Gauge.icns "$RES_DIR/Gauge.icns"
find ./Resources -maxdepth 1 -type d -name '*.lproj' -exec cp -R {} "$RES_DIR/" \;

# Embed Sparkle.framework. -a preserves the symlinks inside Versions/.
cp -a "$SPARKLE_FW" "$FRAMEWORKS_DIR/Sparkle.framework"

SWIFT_SOURCES=$(find Sources -name '*.swift' \
  ! -path 'Sources/Push/*' \
  ! -path 'Sources/Shared/*' \
  | sort)

# Universal binary, macOS 13 (Ventura) minimum. swiftc can't emit a
# multi-arch Mach-O directly, so compile each slice and lipo them.
DEPLOYMENT_TARGET="13.0"
ARM64_BIN="$BUILD_DIR/$APP_NAME-arm64"
X86_64_BIN="$BUILD_DIR/$APP_NAME-x86_64"

for arch_pair in "arm64:$ARM64_BIN" "x86_64:$X86_64_BIN"; do
  arch="${arch_pair%%:*}"
  out="${arch_pair##*:}"
  swiftc \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -O \
    -parse-as-library \
    -F "$SPARKLE_DIR" \
    -framework SwiftUI \
    -framework AppKit \
    -framework UserNotifications \
    -framework ServiceManagement \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$out" \
    $SWIFT_SOURCES
done

lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$MACOS_DIR/$APP_NAME"
rm "$ARM64_BIN" "$X86_64_BIN"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Gauge</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>Gauge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Eric Park. MIT licensed.</string>
  <key>SUFeedURL</key><string>$SU_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
</dict>
</plist>
EOF

# Ad-hoc sign Sparkle's embedded XPC services first (they're inside the
# framework bundle), then the framework itself. The outer .app gets re-signed
# in release.sh after everything's in place.
#
# Sparkle ships both Installer.xpc and Downloader.xpc, but their presence has
# varied across Sparkle versions. Gate on path existence (so missing helpers
# don't fail the build) and propagate any real codesign error — silencing
# them lets "Updater failed to start" reach end users at Check Now time.
XPC_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/Current/XPCServices"
for xpc in Installer.xpc Downloader.xpc; do
  XPC_PATH="$XPC_DIR/$xpc"
  if [[ -d "$XPC_PATH" ]]; then
    codesign --force --sign - --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags "$XPC_PATH"
  fi
done
codesign --force --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework"

echo "✓ built $APP_DIR ($VERSION)"
