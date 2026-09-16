#!/usr/bin/env bash
#
# notarize.sh — submit an artifact to Apple's notary service and staple it.
#
#   APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… Scripts/notarize.sh <artifact> [staple-target]
#
# `staple-target` is what the ticket is attached to, and defaults to the
# artifact. They differ for an app: notarytool accepts a zip of it, but the
# ticket belongs on the .app — stapling a zip does nothing useful.
#
# Notarization is an automated malware scan, not a review of what the software
# does. It is what stops Gatekeeper refusing a directly-distributed app, and it
# is a supported distribution path — not a workaround.
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <artifact> [staple-target]}"
STAPLE_TARGET="${2:-$ARTIFACT}"
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

echo "==> submitting $(basename "$ARTIFACT")"
SUBMIT_OUT=$(xcrun notarytool submit "$ARTIFACT" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait 2>&1)
echo "$SUBMIT_OUT"

STATUS=$(echo "$SUBMIT_OUT" | grep "status:" | tail -1 | awk '{print $NF}')
if [ "$STATUS" != "Accepted" ]; then
  # The submission log is the ONLY place that says which binary was rejected
  # and why. Without fetching it, a failure reads as "status: Invalid" and
  # nothing else, which is unactionable.
  SUB_ID=$(echo "$SUBMIT_OUT" | grep "id:" | head -1 | awk '{print $NF}')
  echo "::error::Notarization failed with status: ${STATUS:-unknown}"
  echo "--- notarization log ---"
  xcrun notarytool log "$SUB_ID" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" || true
  exit 1
fi

# Stapling attaches the ticket to the artifact so Gatekeeper accepts it without
# a network round trip — which is the difference between opening normally and
# failing on a machine that is offline or behind a filtering proxy.
xcrun stapler staple "$STAPLE_TARGET"
xcrun stapler validate "$STAPLE_TARGET"
echo "==> notarized and stapled"
