#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
jobs=()
for s in S1 S2 S3 S4 S5; do
  echo "./drv_orig $s > out/orig_$s.txt"
  for v in "1 300 1 1" "1 300 0 0" "2 300 1 1" "2 300 0 0" "0 300 1 0" "0 300 0 1" "1 150 1 1"; do
    tag=$(echo "$v" | tr ' ' '_')
    echo "./drv_fixed $s $v > out/fix_${tag}_$s.txt"
  done
done | xargs -P 10 -I{} bash -c '{}'
