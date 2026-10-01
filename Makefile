# luac2c — one-file build + test driver.
#
#   mingw32-make            # build luac2c.exe (and the Lua toolchain if missing)
#   mingw32-make lua        # (re)build lua.exe / luac.exe / liblua.a
#   mingw32-make check      # everything below
#   mingw32-make modes      # 16 switch combinations x 24 cases
#   mingw32-make apicheck   # 24 cases against an APICHECK-instrumented liblua
#   mingw32-make stress     # luac2c压力测试.lua (232 self-checking cases)
#   mingw32-make warn       # -Wall -Wextra warning gate on the generated C
#   mingw32-make fuzz       # malformed-input fuzzing
#   mingw32-make clean
#
# GCC can be overridden:  mingw32-make GCC=/c/msys64/mingw64/bin/gcc.exe

GCC     ?= C:/environments/GCC-16.2.0/bin/gcc.exe
AR      ?= $(dir $(GCC))gcc-ar.exe
CFLAGS  ?= -std=c99 -Wall -Wextra -O2
SRC      = lua-5.5.1/src
BUILD    = lua-5.5.1/build
INC      = -I $(SRC) -I lua5.5-include

# Everything liblua.a needs except the two interpreters (which have main()).
LIBOBJS := $(patsubst $(SRC)/%.c,$(BUILD)/%.o,$(filter-out $(SRC)/lua.c $(SRC)/luac.c,$(wildcard $(SRC)/*.c)))

.PHONY: all lua check modes apicheck stress warn fuzz clean

all: luac2c.exe

luac2c.exe: luac2c.c
	$(GCC) $(CFLAGS) -o $@ $<

# --- vendored Lua toolchain -------------------------------------------------
# A fresh clone has no lua.exe / luac.exe / liblua.a: the regression needs all
# three.  Build them here rather than making the user reverse-engineer it.
lua: lua.exe luac.exe $(BUILD)/liblua.a

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: $(SRC)/%.c | $(BUILD)
	$(GCC) -std=c99 -O2 -I $(SRC) -c -o $@ $<

$(BUILD)/liblua.a: $(LIBOBJS)
	$(AR) rcs $@ $^

lua.exe: $(SRC)/lua.c $(BUILD)/liblua.a
	$(GCC) -std=c99 -O2 $(INC) -o $@ $< $(BUILD)/liblua.a -lm

luac.exe: $(SRC)/luac.c $(BUILD)/liblua.a
	$(GCC) -std=c99 -O2 $(INC) -o $@ $< $(BUILD)/liblua.a -lm

# --- tests ------------------------------------------------------------------
# runall.sh needs the toolchain, so every test target depends on `lua`.
check: luac2c.exe lua
	@bash tools/check.sh "$(GCC)"

apicheck: luac2c.exe lua
	@bash tools/check.sh "$(GCC)" --apicheck

modes: luac2c.exe lua
	@bash tools/check.sh "$(GCC)" --modes-only

stress: luac2c.exe lua
	@bash tools/check.sh "$(GCC)" --stress-only

warn: luac2c.exe lua
	@bash tools/check.sh "$(GCC)" --warn-only

fuzz: luac2c.exe lua
	@bash tools/check.sh "$(GCC)" --fuzz-only

clean:
	rm -f luac2c.exe lua.exe luac.exe
	rm -rf $(BUILD) test/.rt .audit/rt
