-- multiple return values, adjustment, tail calls
local function three() return 1, 2, 3 end
print(three())
print((three()))
local a, b, c, d = three()
print(a, b, c, d)
print(three(), 4)
local tmp = { three() }
print(tmp[3])

local function tail(n)
  if n == 0 then return "done" end
  return tail(n - 1)
end
print(tail(100))

local function apply(f, ...) return f(...) end
print(apply(function(x, y) return x * y end, 6, 7))
print(apply(three))

-- string library
print(("hello"):upper())
print(("a,b,c"):gsub(",", ";"))
print(("%s=%d"):format("n", 42))
print(string.rep("ab", 3))
print(("  x  "):match("%s*(%a+)%s*"))
print(#string.format("%5.2f", 3.14159))
for w in ("one two three"):gmatch("%a+") do io.write(w, "/") end
print()

-- string coercion in arithmetic
print("10" + 5, "3.5" * 2)
