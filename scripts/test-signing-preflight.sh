#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Exhaust every presence combination. Only none, signing-only, and all are valid.
for cert in false true; do
  for identity in false true; do
    for apple in false true; do
      for team in false true; do
        for password in false true; do
          expected=1
          if [ "$cert" = "$identity" ] && [ "$apple" = "$team" ] && [ "$apple" = "$password" ]; then
            if [ "$apple" = false ] || [ "$cert" = true ]; then expected=0; fi
          fi
          got=0
          HAS_CERT=$cert HAS_IDENTITY=$identity HAS_NOTARY=$apple HAS_NOTARY_TEAM=$team HAS_NOTARY_PASSWORD=$password \
            sh scripts/signing-preflight.sh >/dev/null 2>&1 || got=$?
          [ "$got" -eq "$expected" ] || { echo 'signing preflight regression'; exit 1; }
        done
      done
    done
  done
done
echo 'PASS: all 32 signing/notarization presence combinations'
