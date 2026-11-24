#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
clang -O2 -arch arm64 -Iorig -c orig/amd.c -o orig/amd.o
clang -O2 -arch arm64 -Iorig driver.c orig/amd.o -o drv_orig -lm
clang -O2 -arch arm64 -Ifixed -I/opt/homebrew/include -c fixed/amd.c -o fixed/amd.o
clang -O2 -arch arm64 -DAMD_FIXED -Ifixed -I/opt/homebrew/include driver.c fixed/amd.o -o drv_fixed -L/opt/homebrew/lib -lfftw3 -lm
