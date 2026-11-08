#!/bin/bash
# cursorblur build script
#   ./build.sh              build the CLI binary ./cursorblur
#   ./build.sh run [--hide] build and launch the CLI binary
#   ./build.sh app          build build/cursorblur.app (universal, ad-hoc signed)
#   ./build.sh release      build the .app, sign, notarize (if configured) and zip it
#
# Release signing (optional, needs an Apple Developer ID):
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<keychain profile created with `xcrun notarytool store-credentials`>
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/cursorblur.app"

build_cli() {
  swiftc -O cursorblur.swift -o cursorblur
  echo "Build ok → ./cursorblur"
}

build_app() {
  mkdir -p build
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos14.0" cursorblur.swift -o "build/cursorblur-$arch"
  done
  [ -f packaging/AppIcon.icns ] || swift scripts/make_icon.swift packaging/AppIcon.icns

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  lipo -create build/cursorblur-arm64 build/cursorblur-x86_64 -output "$APP/Contents/MacOS/cursorblur"
  rm build/cursorblur-arm64 build/cursorblur-x86_64
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/Info.plist > "$APP/Contents/Info.plist"
  cp packaging/AppIcon.icns "$APP/Contents/Resources/"

  if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  else
    codesign --force --sign - "$APP"   # ad-hoc: runs locally, Gatekeeper warns on other Macs
  fi
  codesign --verify --strict "$APP"
  echo "App ok → $APP (v$VERSION, build $BUILD)"
}

release() {
  build_app
  local zip="build/cursorblur-$VERSION.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$zip"
    ditto -c -k --keepParent "$APP" "$zip"
    echo "Notarized and stapled."
  else
    echo "Not notarized (set DEVELOPER_ID and NOTARY_PROFILE to notarize)."
  fi
  shasum -a 256 "$zip"
  echo "Release ok → $zip"
}

case "${1:-}" in
  run)     build_cli; pkill -x cursorblur 2>/dev/null || true; ./cursorblur "${@:2}" ;;
  app)     build_app ;;
  release) release ;;
  "")      build_cli ;;
  *)       echo "usage: $0 [run [--hide] | app | release]"; exit 1 ;;
esac
