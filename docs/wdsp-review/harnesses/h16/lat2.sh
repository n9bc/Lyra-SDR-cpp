#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "# Lyra TX: dsp_rate 96000, dsp_size 4096 (src/wdsp_engine.cpp:1148)"
for cfg in "16384 4096 96000" "8192 4096 96000" "4096 4096 96000" "2048 4096 96000" "1024 4096 96000" "2048 64 96000"; do
  printf "orig m0 %-18s " "$cfg"; out/drv_orig 0 $cfg 0 | head -2 | tr '\n' ' '; echo
done
