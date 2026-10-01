#!/bin/bash
# Run the whole corpus against an APICHECK-instrumented liblua.  A normal build
# compiles Lua's api_check() away, so stack-level contract violations -- pushing
# past ci->top, handing lua_closeslot a level that was never marked -- run to
# completion and only bite on a release build.  This is the oracle for those.
#
#   [GCC=...] [LIB=...] [MODE="--seed 7"] tools/apichk.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
GCC="${GCC:-C:/environments/GCC-16.2.0/bin/gcc.exe}"
LIB="${LIB:-.audit/chk/liblua_chk.a}"
MODES="${MODE:---static}"
TMP=.audit/apichk
mkdir -p $TMP
pass=0; fail=0; failed=""
for f in test/test_*.lua; do
  n=$(basename "$f" .lua)
  ./luac.exe -o "$TMP/$n.luac" "$f" 2>/dev/null || { failed="$failed $n(luac)"; fail=$((fail+1)); continue; }
  ./luac2c.exe "$TMP/$n.luac" $MODES -o "$TMP/$n.c" 2>/dev/null || { failed="$failed $n(tr)"; fail=$((fail+1)); continue; }
  "$GCC" "$TMP/$n.c" -I lua-5.5.1/src -I lua5.5-include -std=c99 -w -O0 -o "$TMP/$n.exe" "$LIB" -lm 2>"$TMP/$n.cerr" || { failed="$failed $n(cc)"; fail=$((fail+1)); continue; }
  # timeout: test_loopcap needs a while at -O0 with every assertion live.
  timeout 60 "$TMP/$n.exe" > "$TMP/$n.out" 2>"$TMP/$n.err"; rc=$?
  ./lua.exe "$f" > "$TMP/$n.ref" 2>&1
  if [ $rc -ne 0 ]; then failed="$failed $n(rc=$rc)"; fail=$((fail+1)); continue; fi
  sed -e 's/[[:space:]]*$//' "$TMP/$n.out" > "$TMP/$n.o2"
  sed -e 's/[[:space:]]*$//' "$TMP/$n.ref" > "$TMP/$n.r2"
  if ! diff -q "$TMP/$n.o2" "$TMP/$n.r2" >/dev/null; then failed="$failed $n(diff)"; fail=$((fail+1)); continue; fi
  pass=$((pass+1))
done
echo "APICHECK[$MODES]: $pass passed, $fail failed"
[ -n "$failed" ] && echo "failed:$failed"
exit $((fail > 0))
