#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
CF="-O2 -arch arm64 -g -I$H -I/opt/homebrew/include -Wno-parentheses"
LF="-L/opt/homebrew/lib -lfftw3 -lpthread"
mkdir -p "$H/bin"
for v in orig fixed; do
  for m in 4096 8; do
    clang $CF -I"$H/$v" -DHARNESS_MAX_ENTRIES=$m "$H/driver.c" "$H/$v/fir.c" $LF -o "$H/bin/${v}_m$m"
    clang $CF -I"$H/$v" -DHARNESS_MAX_ENTRIES=$m -fsanitize=thread "$H/driver.c" "$H/$v/fir.c" $LF -o "$H/bin/${v}_m${m}_tsan"
    clang $CF -I"$H/$v" -DHARNESS_MAX_ENTRIES=$m -fsanitize=address "$H/driver.c" "$H/$v/fir.c" $LF -o "$H/bin/${v}_m${m}_asan"
  done
done
echo built
