#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
CF=(-O2 -arch arm64 -Wno-everything -Icommon)
C=(common/driver.c common/resample_stub.c)
clang "${CF[@]}" -Iorig -o bin_orig "${C[@]}" orig/lmath_core.c orig/snb_core.c orig/asolve_orig.c -lm
F=(fixed/lmath_core.c fixed/snb_core.c fixed/asolve_fixed.c)
clang "${CF[@]}" -Ifixed -DFIXMODE=1 -o bin_fix1 "${C[@]}" "${F[@]}" -lm
clang "${CF[@]}" -Ifixed -DFIXMODE=2 -o bin_fix2 "${C[@]}" "${F[@]}" -lm
clang "${CF[@]}" -Ifixed -DFIXMODE=2 -DWNC=1e-9 -DGAMMA=0.9995 -o bin_fix2g "${C[@]}" "${F[@]}" -lm
echo built
