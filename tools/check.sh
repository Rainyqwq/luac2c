#!/bin/bash
# Unified verification driver.  Everything the project can check lives here so
# "did I break something" is one command instead of four remembered incantations
# scattered over .workbuddy/tm.
#
#   check.sh [GCC=path] [stage...]
#
# Stages (default: all):
#   --modes      16 switch combinations x every test/*.lua case (output == lua.exe)
#   --apicheck   the same cases linked against an APICHECK-instrumented
#                liblua, so Lua's own API assertions fire.  Builds that library
#                into tools/.audit/chk/ on first use.  This is what caught the
#                ci->top overflow and the lua_closeslot level mismatch -- both
#                are silent on a normal build and only surface under a release
#                build's undefined behaviour.
#   --stress    luac2c压力测试.lua (232 self-checking cases) translated and run;
#                its RESULT line must match lua.exe's.  This is the corpus that
#                found the dead-slot and captured-slot liveness defects.
#   --warn       -std=c99 -Wall -Wextra gate: the generated C must compile with
#                zero warnings in every mode.
#   --fuzz       malformed-input fuzzing (fuzz.py) plus "if luac2c accepted it,
#                gcc must accept the result" (fuzzc.py).
#
# Only the stages named on the command line run; --xxx-only is accepted too.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

GCC="${1:-C:/environments/GCC-16.2.0/bin/gcc.exe}"
[ "${GCC#*=}" != "$GCC" ] && GCC="${GCC#*=}"; [ -n "$1" ] && shift
command -v "$GCC" >/dev/null 2>&1 || { echo "gcc not found: $GCC"; exit 1; }
export GCC

NCASES=$(ls test/*.lua 2>/dev/null | wc -l | tr -d ' ')

MODES=('--static' '--seed 0' '--seed 1' '--seed 3' '--seed 7' '--seed 42' \
       '--seed 123' '--seed 12345' '' '--no-clear' '--no-pool' '--no-guard' \
       '--no-mba' '--no-opaque' '--pool-all' '--no-wipe')

want_modes=0; want_api=0; want_warn=0; want_fuzz=0; want_stress=0
if [ $# -eq 0 ]; then want_modes=1; want_api=1; want_warn=1; want_fuzz=1; want_stress=1; fi
for a in "$@"; do
  case "$a" in --modes|--modes-only)     want_modes=1;; esac
  case "$a" in --apicheck|--apicheck-only|--api-only) want_api=1;; esac
  case "$a" in --stress|--stress-only)   want_stress=1;; esac
  case "$a" in --warn|--warn-only)       want_warn=1;; esac
  case "$a" in --fuzz|--fuzz-only)       want_fuzz=1;; esac
done

rc=0

# ---------------------------------------------------------------- modes -----
if [ $want_modes -eq 1 ]; then
  echo "== modes: ${#MODES[@]} switch combinations x $NCASES cases =="
  for m in "${MODES[@]}"; do
    out=$(bash tools/runall.sh "$m" 2>&1)
    echo "$out" | grep -E '^MODE|^FAIL'
    echo "$out" | grep -q ' 0 failed' || rc=1
  done
fi

# ------------------------------------------------------------- apicheck -----
if [ $want_api -eq 1 ]; then
  LIB=tools/.audit/chk/liblua_chk.a
  if [ ! -f "$LIB" ]; then
    echo "== building APICHECK liblua (-DLUA_USE_APICHECK) =="
    mkdir -p tools/.audit/chk
    objs=""
    for f in lua-5.5.1/src/*.c; do
      case "$f" in */lua.c|*/luac.c) continue;; esac
      o=tools/.audit/chk/$(basename "$f" .c).o
      "$GCC" -std=c99 -O1 -DLUA_USE_APICHECK -I lua-5.5.1/src -c -o "$o" "$f" || { echo "APICHECK build failed"; exit 1; }
      objs="$objs $o"
    done
    "${GCC%/*}/gcc-ar.exe" rcs "$LIB" $objs 2>/dev/null \
      || ar rcs "$LIB" $objs 2>/dev/null \
      || { echo "ar failed"; exit 1; }
  fi
  echo "== apicheck: $NCASES cases against APICHECK liblua =="
  for m in '--static' '--seed 0' '--seed 7' '--no-clear' '--no-pool'; do
    out=$(LIB="$LIB" MODE="$m" timeout 900 bash tools/apichk.sh 2>&1)
    echo "$out" | grep -E '^APICHECK'
    echo "$out" | grep -q ' 0 failed' || rc=1
  done
fi

# --------------------------------------------------------------- stress -----
if [ $want_stress -eq 1 ]; then
  echo "== stress: luac2c压力测试.lua through the translator =="
  mkdir -p tools/.audit/stress
  # 压力测试已挪进 test/。runall.sh 只匹配 test_*.lua，天然不会碰它
  # （文件名不匹配通配），所以它归这一道单独跑，只走两种模式。
  S="test/luac2c压力测试.lua"
  [ -f "$S" ] || S="luac2c压力测试.lua"
  ./luac.exe -o tools/.audit/stress/s.luac "$S" 2>/dev/null || { echo "stress: luac failed"; rc=1; }
  ./lua.exe "$S" 2>&1 | grep -v '^SMOKE\|^SKIP' > tools/.audit/stress/ref.txt
  for m in '--static' '--seed 7'; do
    ./luac2c.exe tools/.audit/stress/s.luac $m -o tools/.audit/stress/s.c 2>/dev/null \
      || { echo "stress [$m]: translate failed"; rc=1; continue; }
    "$GCC" tools/.audit/stress/s.c -I lua-5.5.1/src -I lua5.5-include -std=c99 -w -O0 \
        -o tools/.audit/stress/s.exe lua-5.5.1/build/liblua.a -lm 2>/dev/null \
      || { echo "stress [$m]: compile failed"; rc=1; continue; }
    tools/.audit/stress/s.exe 2>&1 | grep -v '^SMOKE\|^SKIP' > tools/.audit/stress/got.txt
    if diff -q tools/.audit/stress/ref.txt tools/.audit/stress/got.txt >/dev/null; then
      echo "stress [$m]: $(grep '^RESULT' tools/.audit/stress/got.txt | head -1)"
    else
      echo "stress [$m]: MISMATCH"; diff tools/.audit/stress/ref.txt tools/.audit/stress/got.txt | head -10; rc=1
    fi
  done
fi

# ----------------------------------------------------------------- warn -----
if [ $want_warn -eq 1 ]; then
  echo "== warn: -Wall -Wextra gate on the generated C =="
  mkdir -p tools/.audit/warn
  n=0; bad=0
  for f in test/test_*.lua; do
    b=$(basename "$f" .lua)
    ./luac.exe -o tools/.audit/warn/$b.luac "$f" 2>/dev/null || continue
    for m in '--static' '--seed 7' '--seed 42'; do
      ./luac2c.exe tools/.audit/warn/$b.luac $m -o tools/.audit/warn/$b.c 2>/dev/null || continue
      w=$("$GCC" -c tools/.audit/warn/$b.c -I lua-5.5.1/src -I lua5.5-include \
              -std=c99 -Wall -Wextra -o /dev/null 2>&1)
      n=$((n+1))
      if [ -n "$w" ]; then bad=$((bad+1)); echo "WARN $b [$m]"; echo "$w" | head -4; fi
    done
  done
  echo "warn: $n compiles, $bad with warnings"
  [ $bad -eq 0 ] || rc=1
fi

# ----------------------------------------------------------------- fuzz -----
if [ $want_fuzz -eq 1 ]; then
  echo "== fuzz: malformed input / malformed output =="
  PY=$(command -v python || command -v python3)
  if [ -z "$PY" ]; then echo "no python: skipping"; else
    $PY tools/fuzz.py 400  2>&1 | tail -3 || rc=1
    $PY tools/fuzzc.py 200 2>&1 | tail -3 || rc=1
  fi
fi

echo
[ $rc -eq 0 ] && echo "CHECK: OK" || echo "CHECK: FAILURES ABOVE"
exit $rc
