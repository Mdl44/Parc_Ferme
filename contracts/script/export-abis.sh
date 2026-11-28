#!/usr/bin/env bash
set -euo pipefail

OUT="../frontend/src/contracts/abis"
mkdir -p "$OUT"

for name in StewardsPanel SuperLicence SuperLicenceV2 TeamBond DocumentRegistry EntryPoint MockAggregator; do
  forge inspect "$name" abi --json > "$OUT/$name.json"
  echo "wrote $OUT/$name.json"
done
