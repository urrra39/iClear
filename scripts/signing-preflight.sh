#!/bin/sh
# Presence flags only. Never print signing credentials.
set -eu
cert=${HAS_CERT:-false}
identity=${HAS_IDENTITY:-false}
apple=${HAS_NOTARY:-false}
team=${HAS_NOTARY_TEAM:-false}
password=${HAS_NOTARY_PASSWORD:-false}
if [ "$cert" != "$identity" ]; then
  echo 'Incomplete signing setup: MACOS_CERTIFICATE and SIGN_IDENTITY must both be configured.' >&2
  exit 1
fi
if [ "$apple" != "$team" ] || [ "$apple" != "$password" ]; then
  echo 'Incomplete notarization setup: NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD are all required.' >&2
  exit 1
fi
if [ "$apple" = true ] && [ "$cert" != true ]; then
  echo 'Notarization requires a Developer ID signing certificate.' >&2
  exit 1
fi
if [ "$apple" = true ]; then
  echo 'Developer ID signing and notarization configured; artifact verification still required.'
elif [ "$cert" = true ]; then
  echo 'Developer ID signing only; this build will NOT be notarized.'
else
  echo 'Ad-hoc candidate only; Developer ID and notarization are unavailable.'
fi
