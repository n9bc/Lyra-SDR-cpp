#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/run"
for v in orig m1 m2 m4 m7; do
 for Z in 0.5 1 1.3 2 5 10 30 60; do
  fz=0; tot=0; worst=-99
  for s in 1 2 3 4 5 6 7 8 9 10; do
   r=$(../drv_$v $Z 0 30 $s | tail -1 | sed -E 's/.*post last 5s (-?[0-9.]+) dB.*/\1/')
   tot=$((tot+1)); if awk "BEGIN{exit !($r > -10)}"; then fz=$((fz+1)); fi
   worst=$(awk "BEGIN{print ($r>$worst)?$r:$worst}")
  done
  echo "$v Z=$Z: NR-off (suppression > -10 dB at 25-30 s after resume) in $fz/$tot seeds; worst suppression $worst dB"
 done
done
