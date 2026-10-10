#!/bin/sh
# Builds universal (arm64 + x86_64) release binaries and assembles dist/iClear.app
# plus dist/iclear-<version>-macos.tar.gz.
#
# Signing: set SIGN_IDENTITY to a "Developer ID Application" identity to sign for
# distribution; otherwise the build is ad-hoc signed (see README, "First launch").
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^public let iclearVersion = "\(.*\)"/\1/p' Sources/ICSystem/Doctor.swift)
# Bundle versions must be numbers: a release candidate (1.1.0-rc.1) is 1.1.0 there; the CLI,
# the artifact names and the release notes carry the full version.
SHORT_VERSION=${VERSION%%-*}
IDENTITY="${SIGN_IDENTITY:--}"
DIST=dist
APP="$DIST/iClear.app"

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release"
[ -d "$BIN" ] || BIN=".build/out/Products/Release"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/iClearMenu" "$APP/Contents/MacOS/iClear"
# Helpers/ keeps iclear apart from iClear on case-insensitive volumes.
cp "$BIN/icleard" "$BIN/icbrake" "$BIN/iclear" "$BIN/ic-hog" "$BIN/ic-ui-probe" "$BIN/ic-call-sim" "$APP/Contents/Helpers/"
cp -R "$BIN/iClear_iClearMenu.bundle" "$APP/Contents/Resources/"
sed "s/@SHORT_VERSION@/$SHORT_VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"

sign() {
    codesign --force --timestamp=none --options runtime --entitlements packaging/iClear.entitlements -s "$IDENTITY" "$@"
}
for f in "$APP/Contents/Helpers"/*; do sign "$f"; done
sign "$APP"

# Command-line tarball: iclear, icleard and the test fixtures used by `iclear selftest` and `iclear bench`.
mkdir -p "$DIST/iclear-$VERSION"
cp "$BIN/iclear" "$BIN/icleard" "$BIN/icbrake" "$BIN/ic-hog" "$BIN/ic-ui-probe" "$BIN/ic-call-sim" "$DIST/iclear-$VERSION/"
for f in "$DIST/iclear-$VERSION"/*; do sign "$f"; done
tar -C "$DIST" -czf "$DIST/iclear-$VERSION-macos.tar.gz" "iclear-$VERSION"
(cd "$DIST" && ditto -c -k --keepParent iClear.app "iClear-$VERSION.zip")

lipo -info "$APP/Contents/Helpers/icleard"
echo "Built $APP and $DIST/iclear-$VERSION-macos.tar.gz (signed with: $IDENTITY)"
