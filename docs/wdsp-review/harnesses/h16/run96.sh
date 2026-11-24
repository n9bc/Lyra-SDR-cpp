#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for p in 30 40; do
  echo "######## precomp $p dB, 96 kHz, bsize 4096 (Lyra TX)"
  echo "== A orig m0 fsize16384";               out/drv_orig  0 16384 4096 96000 $p
  echo "== B orig m0 fsize2048 (interim)";      out/drv_orig  0 2048 4096 96000 $p
  echo "== D fixed m1 fsize2048 R20 k6 a1ms r60ms"; out/drv_fixed 1 2048 4096 96000 $p 20 6 0.001 0.06
  echo "== D2 fixed m1 fsize1024 R20 k6 a1ms r60ms"; out/drv_fixed 1 1024 4096 96000 $p 20 6 0.001 0.06
done
