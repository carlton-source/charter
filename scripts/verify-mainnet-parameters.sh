#!/usr/bin/env bash
# Verify charter-pool's ballast math against every live PoX-5 bond registration.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${HERE}/check_ratio.py" "${API:-https://api.hiro.so}"
echo
echo "OK - charter-pool's floor matches every registration pox-5 accepted."
