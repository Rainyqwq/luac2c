#!/bin/bash
# 全量回归：每个 test_*.lua 走 luac -> luac2c -> gcc -> run -> 与 lua.exe 比对
ROOT="$(cd "$(dirname "$0")/.." && pwd)"         # tools/ -> 工程根
cd "$ROOT/test" || exit 1
GCC="${GCC:-$(command -v gcc)}"                  # 本机 gcc 用环境变量 GCC 指定
if [ -z "$GCC" ]; then
  for c in /c/environments/GCC-16.2.0/bin /c/mingw64/bin /c/msys64/mingw64/bin \
           /c/TDM-GCC-64/bin /c/MinGW/bin; do
    [ -x "$c/gcc.exe" ] && GCC="$c/gcc.exe" && break
  done
fi
if [ -z "$GCC" ]; then echo "gcc not found: set GCC=/path/to/gcc.exe"; exit 1; fi
MODE="$1"
TMPDIR=.rt
mkdir -p $TMPDIR
pass=0; fail=0; failed=""
for f in test_*.lua; do
  n="${f%.lua}"
  ../luac.exe -o "$TMPDIR/$n.luac" "$f" 2>/dev/null
  if [ $? -ne 0 ]; then echo "FAIL $n (luac)"; fail=$((fail+1)); failed="$failed $n"; continue; fi
  ../luac2c.exe "$TMPDIR/$n.luac" $MODE -o "$TMPDIR/${n}_out.c" 2>"$TMPDIR/$n.gen.err"
  if [ $? -ne 0 ]; then echo "FAIL $n (luac2c)"; fail=$((fail+1)); failed="$failed $n"; continue; fi
  "$GCC" "$TMPDIR/${n}_out.c" -I ../lua-5.5.1/src -I ../lua5.5-include -std=c99 -w -O0 \
      -o "$TMPDIR/${n}_out.exe" ../lua-5.5.1/build/liblua.a -lm 2>"$TMPDIR/$n.cc.err"
  if [ $? -ne 0 ]; then echo "FAIL $n (gcc)"; head -5 "$TMPDIR/$n.cc.err"; fail=$((fail+1)); failed="$failed $n"; continue; fi
  "./$TMPDIR/${n}_out.exe" > "$TMPDIR/$n.gen" 2>&1
  ../lua.exe "$f" > "$TMPDIR/$n.ref" 2>&1
  # 归一化：去掉尾部空白差异
  sed -e 's/[[:space:]]*$//' "$TMPDIR/$n.gen" > "$TMPDIR/$n.gen2"
  sed -e 's/[[:space:]]*$//' "$TMPDIR/$n.ref" > "$TMPDIR/$n.ref2"
  if diff -q "$TMPDIR/$n.gen2" "$TMPDIR/$n.ref2" >/dev/null; then
    echo "pass $n"; pass=$((pass+1))
  else
    echo "FAIL $n (diff)"; fail=$((fail+1)); failed="$failed $n"
  fi
done
echo "MODE[$MODE] => $pass passed, $fail failed"
if [ -n "$failed" ]; then echo "failed:$failed"; fi
