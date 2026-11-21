#!/usr/bin/env bash
# Build a universal ToSlash.app and wrap it in dist/ToSlash-<version>.dmg for a GitHub release.
# The version comes from Info.plist. Without TOSLASH_SIGN_IDENTITY the app is signed ad hoc,
# so Gatekeeper blocks the first open until the user allows it (see Install in the README).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version="$(plutil -extract CFBundleShortVersionString raw "$here/Info.plist")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
"$here/build.sh" "$stage"
ln -s /Applications "$stage/Applications"
mkdir -p "$here/dist"
dmg="$here/dist/ToSlash-$version.dmg"
hdiutil create -quiet -volname "ToSlash $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
echo "packaged $dmg"
shasum -a 256 "$dmg"
