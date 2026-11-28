#!/usr/bin/env bash
set -euo pipefail

layout() {
  forge inspect "$1" storageLayout --json | jq -c '[.storage[] | {label, slot, offset, type}]'
}

old=$(layout SuperLicence)
new=$(layout SuperLicenceV2)

missing=$(jq -n --argjson old "$old" --argjson new "$new" '[$old[] | select(. as $v | $new | index([$v]) | not)]')
if [ "$missing" != "[]" ]; then
  echo "SuperLicenceV2 breaks the storage layout of SuperLicence:"
  echo "$missing" | jq .
  exit 1
fi

added=$(jq -rn --argjson old "$old" --argjson new "$new" '[$new[] | select(. as $v | $old | index([$v]) | not) | "\(.label) (slot \(.slot))"] | join(", ")')
echo "storage layout OK: every SuperLicence slot is unchanged in SuperLicenceV2; V2 adds $added"
