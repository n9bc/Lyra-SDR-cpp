#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
cd "$H"
for p in 20 30 40; do
  echo "######## precomp $p dB, 48 kHz, bsize 256"
  echo "== A orig m0 fsize16384";            OUTRAW=out/A_$p.raw out/drv_orig  0 16384 256 48000 $p
  echo "== C fixed-build m0 fsize16384";     OUTRAW=out/C_$p.raw out/drv_fixed 0 16384 256 48000 $p
  echo "== B orig m0 fsize1024 (interim)";   out/drv_orig  0 1024 256 48000 $p
  echo "== D fixed m1 fsize1024 R20 k6 a1ms r60ms"; out/drv_fixed 1 1024 256 48000 $p 20 6 0.001 0.06
  echo "== E fixed m1 fsize512  R20 k6 a1ms r60ms"; out/drv_fixed 1 512 256 48000 $p 20 6 0.001 0.06
  echo "== F fixed m1 fsize1024 hardclip no-smooth"; out/drv_fixed 1 1024 256 48000 $p 1000 0.1 0.00001 0.00001
  cmp out/A_$p.raw out/C_$p.raw && echo "A==C bit-exact"
done
