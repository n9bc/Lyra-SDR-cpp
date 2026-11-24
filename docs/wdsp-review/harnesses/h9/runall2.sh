#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for s in S2 S3 S4 S5 S1; do
  echo "./drv_orig $s > out2/orig_$s.txt"
  for v in "1 300 1 1" "1 300 0 0" "2 300 1 1" "2 300 0 0" "0 300 1 0" "0 300 0 1"; do
    echo "./drv_fixed $s $v > out2/fix_$(echo "$v" | tr ' ' '_')_$s.txt"
  done
done | xargs -P 8 -I{} bash -c '{}'
echo ALLDONE
