#!/usr/bin/env bash
# Build ToSlash.app into $1 (default ~/Applications), and relaunch it if it was running.
# TOSLASH_SIGN_IDENTITY="Developer ID Application: …" signs for distribution; otherwise ad hoc.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:-$HOME/Applications}/ToSlash.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/Info.plist" "$app/Contents/Info.plist"
# icon/make-icon.swift regenerates this from the design.
cp "$here/icon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# One binary for Apple silicon and Intel Macs.
obj="$(mktemp -d)"
trap 'rm -rf "$obj"' EXIT
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "$obj/$arch" "$here"/Sources/*.swift
done
lipo -create -output "$app/Contents/MacOS/ToSlash" "$obj/arm64" "$obj/x86_64"
if [[ -n ${TOSLASH_SIGN_IDENTITY:-} ]]; then
  codesign --force --options runtime --timestamp --sign "$TOSLASH_SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
echo "built $app"
exe="^$app/Contents/MacOS/ToSlash"
if pkill -f "$exe"; then
  # open only starts a new copy once the old one has exited; before that it just activates it.
  while pgrep -f "$exe" >/dev/null; do sleep 0.1; done
  open "$app"
fi
