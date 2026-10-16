#!/bin/sh
# Exercise the verifier's failure propagation with disposable, fake release assets.
set -eu
VERIFY=$(cd "$(dirname "$0")" && pwd)/verify-release.sh
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/assets" "$ROOT/iclear-9.9.9" "$ROOT/iClear.app/Contents/MacOS" "$ROOT/iClear.app/Contents/Helpers"
cat > "$ROOT/iclear-9.9.9/iclear" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
  --version) echo 'iclear 9.9.9' ;;
  selftest) exit 0 ;;
  doctor)
    printf 'diagnostic\n'
    [ "$FAIL_AT" != doctor ] || exit 31 ;;
  migrate)
    if [ "${2:-}" = --dry-run ]; then
      [ "$FAIL_AT" != dry-run ] || exit 32
    else
      [ "$FAIL_AT" != migrate ] || exit 33
      mkdir -p "$ICLEAR_HOME/Library/Application Support/iClear-relcheck"
      cp "$ICLEAR_HOME/Library/Application Support/iClean/config.json" "$ICLEAR_HOME/Library/Application Support/iClear-relcheck/config.json"
    fi ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$ROOT/iclear-9.9.9/iclear"
cp "$ROOT/iclear-9.9.9/iclear" "$ROOT/iClear.app/Contents/Helpers/iclear"
cp "$ROOT/iclear-9.9.9/iclear" "$ROOT/iClear.app/Contents/MacOS/iClear"
tar -czf "$ROOT/assets/iclear-9.9.9-macos.tar.gz" -C "$ROOT" iclear-9.9.9
ditto -c -k --keepParent "$ROOT/iClear.app" "$ROOT/assets/iClear-9.9.9.zip"
(cd "$ROOT/assets" && shasum -a 256 ./*.gz ./*.zip > SHA256SUMS.txt)
printf '#!/bin/sh\necho "arm64 x86_64"\n' > "$ROOT/bin/lipo"
printf '#!/bin/sh\necho "Identifier=test.fixture"\n' > "$ROOT/bin/codesign"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/xattr"
chmod +x "$ROOT/bin/"*
export PATH="$ROOT/bin:$PATH"
for item in doctor:31 dry-run:32 migrate:33 none:0; do
  FAIL_AT=${item%:*}; expected=${item#*:}; export FAIL_AT
  status=0
  sh "$VERIFY" "$ROOT/assets" 9.9.9 --no-mic > "$ROOT/result.log" 2>&1 || status=$?
  if [ "$status" -ne "$expected" ]; then
    cat "$ROOT/result.log"
    echo "$FAIL_AT: expected exit $expected, got $status" >&2
    exit 1
  fi
  if [ "$status" -eq 0 ]; then
    grep -q 'all checks passed' "$ROOT/result.log"
  elif grep -q 'all checks passed' "$ROOT/result.log"; then
    echo "$FAIL_AT: failure was reported as success" >&2
    exit 1
  fi
done
echo 'Release verifier: success and all three command failures checked.'
