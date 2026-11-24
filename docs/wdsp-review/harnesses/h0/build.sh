#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
C=(clang -O2 -arch arm64 -w -Icommon -I/opt/homebrew/include)
L=(common/calculus.o common/zetaHat.o common/meterlog10.o -L/opt/homebrew/lib -lfftw3 -lm)
"${C[@]}" driver.c orig/emnr.o "${L[@]}" -o drv_orig
for m in 1 2 4 7; do "${C[@]}" driver.c fixed/emnr_m$m.o "${L[@]}" -o drv_m$m; done
