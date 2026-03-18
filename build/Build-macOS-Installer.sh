#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v pkgbuild >/dev/null 2>&1; then
  echo "pkgbuild was not found. Run this script on macOS with Xcode command line tools installed." >&2
  exit 1
fi

OUTPUT_DIR="$REPO_ROOT/artifacts/installer-macos"
WORK_DIR="$REPO_ROOT/artifacts/macos-build"
ROOT_DIR="$WORK_DIR/root"
APP_DIR="$ROOT_DIR/Applications/OpenClaw Launcher.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_SIGN_IDENTITY="${OPENCLAW_MACOS_APP_SIGN_IDENTITY:-}"
PKG_SIGN_IDENTITY="${OPENCLAW_MACOS_PKG_SIGN_IDENTITY:-}"

mkdir -p "$OUTPUT_DIR" "$APP_MACOS"
rm -rf "$WORK_DIR"
mkdir -p "$APP_MACOS"

cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>OpenClaw Launcher</string>
  <key>CFBundleExecutable</key>
  <string>OpenClawLauncher</string>
  <key>CFBundleIdentifier</key>
  <string>ai.openclaw.launcher.macos</string>
  <key>CFBundleName</key>
  <string>OpenClaw Launcher</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
</dict>
</plist>
PLIST

cat > "$APP_MACOS/OpenClawLauncher" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

if command -v openclaw >/dev/null 2>&1; then
  (openclaw gateway start >/dev/null 2>&1 || true) &
fi

TOKEN_FILE="$HOME/.openclaw/gateway-token"
TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
fi

URL="http://127.0.0.1:18789/"
if [[ -n "$TOKEN" ]]; then
  URL="${URL}?token=${TOKEN}"
fi

open "$URL"
LAUNCHER

chmod +x "$APP_MACOS/OpenClawLauncher"
chmod +x "$REPO_ROOT/macos/pkg-scripts/postinstall"

VERSION="${OPENCLAW_MACOS_VERSION:-$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "1.0.0")}"
PKG_PATH="$OUTPUT_DIR/OpenClawSetup-macOS.pkg"
UNSIGNED_PKG_PATH="$WORK_DIR/OpenClawSetup-macOS-unsigned.pkg"

if [[ -n "$APP_SIGN_IDENTITY" ]]; then
  if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign was not found, but OPENCLAW_MACOS_APP_SIGN_IDENTITY is set." >&2
    exit 1
  fi

  echo "Signing app bundle with identity: $APP_SIGN_IDENTITY"
  codesign --force --deep --timestamp --options runtime --sign "$APP_SIGN_IDENTITY" "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

pkgbuild \
  --root "$ROOT_DIR" \
  --scripts "$REPO_ROOT/macos/pkg-scripts" \
  --identifier "ai.openclaw.installer.macos" \
  --version "$VERSION" \
  "$UNSIGNED_PKG_PATH"

if [[ -n "$PKG_SIGN_IDENTITY" ]]; then
  if ! command -v productsign >/dev/null 2>&1; then
    echo "productsign was not found, but OPENCLAW_MACOS_PKG_SIGN_IDENTITY is set." >&2
    exit 1
  fi

  echo "Signing installer package with identity: $PKG_SIGN_IDENTITY"
  productsign --sign "$PKG_SIGN_IDENTITY" "$UNSIGNED_PKG_PATH" "$PKG_PATH"
  pkgutil --check-signature "$PKG_PATH"
  rm -f "$UNSIGNED_PKG_PATH"
else
  mv "$UNSIGNED_PKG_PATH" "$PKG_PATH"
fi

echo "Built $PKG_PATH"
