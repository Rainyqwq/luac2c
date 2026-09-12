-- bitwise, integer division, numeric edge cases
print(5 & 3, 5 | 3, 5 ~ 3, ~0)
print(1 << 4, 256 >> 4, -8 >> 1, -8 // 1)
print(7 // 2, -7 // 2, 7.0 // 2, 2^10 // 3)
print(7 % 3, -7 % 3, 7.5 % 2, 2^-1)
print(math.maxinteger, math.mininteger)
print(math.maxinteger + 1 == math.mininteger)
local function norm(s)
  s = tostring(s)
  s = (s:gsub("^.-:%d+: ", ""))
  s = (s:gsub(" %(local '[^']*'%)", ""))
  s = (s:gsub(" %(global '[^']*'%)", ""))
  return s
end
local function P(ok, ...)
  if ok then return true, ... end
  return false, norm((...))
end
print(P(pcall(function() return 1 // 0 end)))
print(P(pcall(function() return 1 % 0 end)))
print(P(pcall(function() return (nil) & 1 end)))
print(P(pcall(function() return {} < {} end)))
print((1 << 62), (1 << 62) * 2 == 0 or "big")
print(3 | 0, 3 & -1, ~(-1))

-- math library
print(math.floor(3.7), math.ceil(3.2), math.floor(-3.7))
print(math.abs(-5), math.abs(-5.5))
print(math.fmod(7, 3), math.fmod(-7, 3))
print(math.sqrt(16), 2^0.5)
print(math.tointeger(3.0) == 3, math.tointeger(3.5))
print(math.type(1), math.type(1.0), math.type("1"))
print(math.max(1, 5, 3), math.min(1, 5, 3))
print(math.ult(1, 2), math.ult(2, 1))
print(string.format("%.3f", math.pi))
math.randomseed(42)
local r = {}
for i = 1, 3 do r[i] = math.random(100) end
print(#r == 3)
print(math.random(3, 3))

-- integer/float comparison semantics
print(1 == 1.0, "1" == 1, 1 < 1.0, 2 >= 2.0)
print(0.1 + 0.2 == 0.3)
print(10 // 3, 10 / 3, 10 % 3)
print(("n"):rep(3))

-- string coercion in arithmetic
print("10" + 5, "3" * "4")
print(10 .. "" == "10", 1.0 .. "")

-- numeric for with float step and huge limits
local c = 0
for i = 1, 2, 0.5 do c = c + 1 end
print(c)

-- vararg select and counting
local function cnt(...) return select("#", ...) end
print(cnt(), cnt(nil), cnt(nil, nil), cnt(1, 2, 3))

-- integer division metamethod-free
print(7 // 2 * 2 + 7 % 2 == 7)
print("bitwise-ok")
