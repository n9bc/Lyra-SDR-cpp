#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
cd "$H"
clang -O2 -arch arm64 -Wall -Wno-unused-variable -I common -I orig -I/opt/homebrew/include driver.c orig/cfcomp.c common/nurbs_stub.c -L/opt/homebrew/lib -lfftw3 -o out/drv_orig
clang -O2 -arch arm64 -Wall -Wno-unused-variable -DFIXED -I common -I fixed -I/opt/homebrew/include driver.c fixed/cfcomp.c common/nurbs_stub.c -L/opt/homebrew/lib -lfftw3 -o out/drv_fixed
