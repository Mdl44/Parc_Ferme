#!/usr/bin/env bash
set -euo pipefail

OUT="../frontend/src/contracts/abis"
mkdir -p "$OUT"

for name in StewardsPanel SuperLicence TeamBond DocumentRegistry; do
  forge inspect "$name" abi --json > "$OUT/$name.json"
  echo "wrote $OUT/$name.json"
done
