#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
C=(clang -O2 -arch arm64 -w -Icommon_f -I/opt/homebrew/include)
for f in calculus zetaHat; do "${C[@]}" -Ddouble=float -c common_f/$f.c -o common_f/$f.o; done; "${C[@]}" -c common_f/meterlog10.c -o common_f/meterlog10.o
L=(common_f/calculus.o common_f/zetaHat.o common_f/meterlog10.o -L/opt/homebrew/lib -lfftw3f -lm)
"${C[@]}" driver.c orig/emnr.c "${L[@]}" -o drvf_orig
for m in 1 2 4 7; do "${C[@]}" -DFIXMODE=$m driver.c fixed/emnr.c "${L[@]}" -o drvf_m$m; done
