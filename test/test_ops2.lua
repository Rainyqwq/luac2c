-- test_ops2.lua -- force opcodes the main corpus never reaches:
--   *K arithmetic with constants outside the 8-bit immediate range (ADDK/SUBK/DIVK/BORK/BXORK),
--   register-operand bitwise (BAND/BOR/BXOR/SHL/SHR), immediate shifts (SHLI/SHRI),
--   POW with a register exponent, BNOT, NOT, and TESTSET.
local out = {}
local function p(...)
  local n = select('#', ...)
  local s = {}
  for i = 1, n do s[i] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(s, " ")
end

local x = 7
p("addk",  x + 1000)      -- ADDK   (constant, not ADDI)
p("subk",  x - 1000)      -- SUBK
p("divk",  x / 1000)      -- DIVK   (float result)
p("bork",  x | 4096)      -- BORK
p("bxork", x ~ 4096)      -- BXORK

local y = 3
p("shl",   x << y)        -- SHL    (register shift)
p("shr",   x >> y)        -- SHR
p("shli",  x << 3)        -- SHLI   (immediate shift)
p("shri",  x >> 3)        -- SHRI

local w = 0xF0
p("band",  x & w)         -- BAND   (register operands)
p("bor",   x | w)         -- BOR
p("bxor",  x ~ w)         -- BXOR

p("bnot",  ~x)            -- BNOT
p("not",   not x)         -- NOT
p("pow",   x ^ y)         -- POW    (register exponent)

-- << with a constant on the LEFT is not commutative, so it stays a
-- constant-left shift -> SHLI (whereas 'x << 3' is rewritten to 'SHRI -3').
p("shli_const", 3 << x)

-- and/or producing a value in a *different* register -> TESTSET
local a, b = 1, nil
local c = b or a
local d = a and b
local e = b and a
local f = a or b
p("ts", c, d, e, f)

-- The 5.5 'global' declaration emits ERRNNIL to ensure the global is not
-- already defined before it is stored.
local function gtest()
  global gg = 42
  return gg
end
p("global", gtest())

-- Naming the vararg table in the parameter list makes it directly
-- indexable, which the compiler lowers to GETVARG.
local function vtest(... v)
  return v[1], v[2], v[3]
end
p("getvarg", vtest(10, 20, 30))

print(table.concat(out, "\n"))
