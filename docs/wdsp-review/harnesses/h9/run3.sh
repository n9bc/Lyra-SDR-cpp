#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for s in S3 S4; do for v in "1 300 2 1" "1 300 2 0" "0 300 2 0"; do
  echo "./drv_fixed2 $s $v > out2/fix2_$(echo "$v" | tr ' ' '_')_$s.txt"; done; done | xargs -P 6 -I{} bash -c '{}'
echo RUN3DONE
