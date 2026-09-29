-- Opcodes whose A field is a don't-care.
--
-- luaK_ret() writes 'freereg' into A for every return form, and for a function
-- whose body exactly fills its register frame that value is legitimately one
-- past the last live register -- i.e. equal to maxstacksize.
--
--   OP_RETURN0     takes no operands at all (see lopcodes.h)
--   OP_RETURN B==1 returns zero values, so R[A] is never read
--
-- The VM never looks at A in either case, and the disassembler prints "0 out"
-- to say so.  A validator that range-checks A uniformly for every opcode
-- therefore rejects perfectly valid chunks -- the two minimal shapes below
-- were the first inputs in this project's corpus to trigger it.
--
-- Both functions fill their frame exactly and then return nothing.

-- fills 2 slots, then an implicit return: RETURN0 with A == maxstack == 2
local f1 = function()
  local x, y = 1, 2
end

-- explicit bare return after filling the frame: also RETURN0, A == maxstack
local f2 = function()
  local x, y = 1, 2
  return
end

-- the short-circuit form produces RETURN with B == 1 (zero results, A unused)
local f3 = function()
  local called = false
  local function g() called = true return true end
  local _ = false and g()
  return called
end

-- a normal one-value return still uses A, so it must keep working
local f4 = function()
  local x, y = 1, 2
  return x + y
end

-- fill a larger frame exactly, then return nothing
local f5 = function()
  local a, b, c, d, e, f, g, h = 1, 2, 3, 4, 5, 6, 7, 8
  if a > b then return end
end

print("f1", f1() == nil)
print("f2", f2() == nil)
print("f3", f3())
print("f4", f4())
print("f5", f5() == nil)

-- and the same shapes called for real, to be sure the frames stay consistent
local function use1()
  local x, y = 10, 20
  local r = x + y
  local t = {x, y}
  return r + #t
end
print("use1", use1())

-- a function that returns nothing but is called in a multiple assignment
local function nothing() local p, q = 1, 2 end
local u, v = nothing()
print("nothing", u == nil, v == nil)

-- call it where its result is truncated by a surrounding expression
print("in-expr", (nothing()) == nil)

-- nested: the inner one fills its frame exactly too
local function outer()
  local function inner() local m, n = 1, 2 end
  inner()
  return "ok"
end
print("outer", outer())
