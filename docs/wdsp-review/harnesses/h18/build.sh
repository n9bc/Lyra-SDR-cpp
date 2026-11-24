#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
CF=(-O2 -arch arm64 -Wall -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-function -I/opt/homebrew/include)
LF=(-L/opt/homebrew/lib -lfftw3 -lm)
clang "${CF[@]}" -I"$H/orig"  -I"$H/shim"                  "$H/driver.c" -o "$H/run_orig"  "${LF[@]}"
clang "${CF[@]}" -I"$H/fixed" -I"$H/shim" -DKEEPSTATE_ONLY "$H/driver.c" -o "$H/run_keep"  "${LF[@]}"
clang "${CF[@]}" -I"$H/fixed" -I"$H/shim" -DFIXEDBUILD     "$H/driver.c" -o "$H/run_fixed" "${LF[@]}"
echo built
