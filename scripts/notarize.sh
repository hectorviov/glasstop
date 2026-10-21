#!/usr/bin/env bash
# Submits a signed .zip/.dmg/.pkg to Apple's notary service, waits for the verdict and, for a
# disk image, staples the ticket so Gatekeeper accepts it offline. (A .zip can't be stapled:
# staple the .app inside it afterwards with `xcrun stapler staple Glasstop.app`.)
#
# Credentials, either:
#   NOTARY_PROFILE=name                     a profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   an App Store Connect API key (.p8)
#
#   NOTARY_TIMEOUT=2h                       how long to wait (default 2h; Apple's first submissions
#                                           for a new team can take well over 30 minutes)
#
# Usage: scripts/notarize.sh <file>
set -euo pipefail
FILE="$1"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    auth=(--keychain-profile "$NOTARY_PROFILE")
else
    auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

result=$(mktemp)
status=0
xcrun notarytool submit "$FILE" "${auth[@]}" --wait --timeout "${NOTARY_TIMEOUT:-2h}" \
    --output-format json > "$result" || status=$?
if [[ $status -ne 0 ]]; then
    cat "$result"
    echo "notarytool exited with $status (a timeout means Apple is still processing; it keeps"
    echo "going on Apple's side, so re-running later is usually quick)" >&2
    exit "$status"
fi
id=$(plutil -extract id raw -o - "$result")
status=$(plutil -extract status raw -o - "$result")
echo "Notarization $id: $status"
if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
fi

case "$FILE" in
    *.dmg|*.pkg|*.app) xcrun stapler staple "$FILE" && xcrun stapler validate "$FILE" ;;
esac
