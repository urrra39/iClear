#!/bin/sh
# Checks a release's assets before they are published: checksums, universal binaries,
# signature, version, quick selftest, doctor and migrate in a temporary home. Exits
# non-zero at the first failure.
# Usage: scripts/verify-release.sh <directory with the assets> <version> [--no-mic]
set -eu
DIR=$(cd "$1" && pwd); V="$2"; MIC="${3:-}"
W=$(mktemp -d); H=$(mktemp -d)
trap 'rm -rf "$W" "$H"' EXIT
cd "$DIR"
echo "== checksums"; shasum -a 256 -c SHA256SUMS.txt
tar -xzf "iclear-$V-macos.tar.gz" -C "$W"; ditto -x -k "iClear-$V.zip" "$W/app"
T="$W/iclear-$V"; APP="$W/app/iClear.app"
echo "== universal binaries"
for b in "$T"/* "$APP"/Contents/MacOS/* "$APP"/Contents/Helpers/*; do
  a=$(lipo -archs "$b"); echo "$(basename "$b"): $a"
  case "$a" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not universal: $b"; exit 1 ;; esac
done
echo "== signature"; codesign -dv "$APP" 2>&1 | grep -E "Identifier|Format|Signature|TeamIdentifier"
codesign --verify --deep --strict "$APP"; echo "verify ok"
xattr -dr com.apple.quarantine "$T" "$APP" 2>/dev/null || true
echo "== version"; got=$("$T/iclear" --version); echo "$got"; [ "$got" = "iclear $V" ]
[ "$("$APP/Contents/Helpers/iclear" --version)" = "iclear $V" ]
export HOME="$H" ICLEAR_HOME="$H" ICLEAR_INSTANCE=relcheck
echo "== selftest --quick $MIC"; "$T/iclear" selftest --quick $MIC
echo "== doctor"; "$T/iclear" doctor | head -8
echo "== migrate (simulated iClean install)"
mkdir -p "$H/Library/Application Support/iClean"
printf '{"mode":"observe"}' > "$H/Library/Application Support/iClean/config.json"
"$T/iclear" migrate --dry-run | head -4
"$T/iclear" migrate | head -4
echo "== all checks passed for $V"
