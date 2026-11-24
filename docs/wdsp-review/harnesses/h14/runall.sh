#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; cd "$H"
pmax(){ echo $(( 16384*64/$1 )); }; pmin(){ echo $(( 4096*64/$1 )); }
for B in 64 128 256 512 1024; do
  for R in 16384 4096; do
    ./orig/run  $B $B $R 100 0 2 900 0 0 7 out/s1_orig_B${B}_R${R}.csv  > out/s1_orig_B${B}_R${R}.txt &
    ./fixed/run $B $B $R 100 0 2 900 0 0 7 out/s1_fixed_B${B}_R${R}.csv > out/s1_fixed_B${B}_R${R}.txt &
    ./orig/run  $B $B $R 100 0 2 900 0 0 7 out/s1_origT_B${B}_R${R}.csv $(pmin $B) $(pmax $B) > out/s1_origT_B${B}_R${R}.txt &
  done
  wait
  for v in orig fixed; do ./$v/run $B $B 16384 100 0 2 800 400 100 7 out/s2_${v}_B${B}.csv > out/s2_${v}_B${B}.txt & done
  ./orig/run $B $B 16384 100 0 2 800 400 100 7 out/s2_origT_B${B}.csv $(pmin $B) $(pmax $B) > out/s2_origT_B${B}.txt &
  wait
done
