#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
for d in orig fixed; do
  clang -O2 -arch arm64 -w -I"$H/shim" -I"$H/$d" -I/opt/homebrew/include \
    "$H/driver.c" "$H/$d/fir.c" "$H/$d/firmin.c" "$H/$d/wcpAGC.c" \
    -L/opt/homebrew/lib -lfftw3 -lm -o "$H/wbfm_$d"
done
