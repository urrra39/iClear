#!/bin/sh
# Renders docs/images/menu-{en,uz}.png (popover) and window-{en,uz}.png (window content)
# from the menu app, connected to an
# isolated, observe-only daemon (it never pauses anything and does not touch the real
# install). Run after `swift build -c release`.
set -eu
cd "$(dirname "$0")/.."
BIN=.build/release
home=$(mktemp -d /tmp/iclear-shot.XXXXXX)
export ICLEAR_HOME="$home" ICLEAR_INSTANCE=shot ICLEAR_OBSERVE_ONLY=1
"$BIN/icleard" 2>/dev/null &
daemon=$!
trap 'kill $daemon 2>/dev/null; rm -rf "$home"' EXIT
for _ in $(seq 1 50); do "$BIN/iclear" status >/dev/null 2>&1 && break; sleep 0.2; done
sleep 3
# Inside an app bundle, as shipped: the Info.plist lists the localizations.
app="$home/iClear.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$BIN/iClearMenu" "$app/Contents/MacOS/iClear"
cp -R "$BIN/iClear_iClearMenu.bundle" "$app/Contents/Resources/"
cp packaging/AppIcon.icns "$app/Contents/Resources/"
version=$(sed -n 's/^public let iclearVersion = "\(.*\)"/\1/p' Sources/ICSystem/Doctor.swift)
sed "s/@SHORT_VERSION@/${version%%-*}/g" packaging/Info.plist > "$app/Contents/Info.plist"
for lang in en uz; do
    "$app/Contents/MacOS/iClear" --snapshot "$PWD/docs/images/menu-$lang.png" --light -AppleLanguages "($lang)"
    "$app/Contents/MacOS/iClear" --snapshot "$PWD/docs/images/window-$lang.png" --window --light -AppleLanguages "($lang)"
done
echo "wrote docs/images/menu-{en,uz}.png and window-{en,uz}.png"
