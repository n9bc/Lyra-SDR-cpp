#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for v in orig fixed; do
  clang -O2 -arch arm64 -Wall -Wno-unused-function -Ishim -I"$v" -o "dexp_$v" driver.c "$v/dexp.c" -lm
done
