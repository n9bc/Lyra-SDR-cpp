#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for s in 1 2 3 4 5 6; do for a in 0 10 30; do for b in orig fix1 fix2 fix2g; do
  printf "%-6s " "$b"; ./bin_$b $s $a; done; echo; done; done
