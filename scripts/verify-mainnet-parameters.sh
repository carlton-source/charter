#!/usr/bin/env bash
# Verify charter-pool's ratio math against live PoX-5 bond parameters.
# required-ustx-for is the one calculation the whole pool depends on;
# this fails loudly if it ever drifts from what mainnet actually locks.
set -euo pipefail
API="${API:-https://api.hiro.so}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Fetching bonds from ${API} ..."
curl -sS --max-time 30 "${API}/extended/v3/staking/bonds?limit=20" \
  | python3 "${HERE}/check_ratio.py"

echo
echo "OK - charter-pool ratio math agrees with mainnet."
