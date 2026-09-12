-- varargs (hidden args), select, table.pack/unpack
local function sum(...)
  local n = select("#", ...)
  local s = 0
  for i = 1, n do s = s + (select(i, ...)) end
  return s, n
end
print(sum(1, 2, 3, 4))
print(sum())
print(sum(10))

local function head(...) return ... end
print(head(1, 2, 3))

local function pack(...) return table.pack(...) end
local p = pack("a", nil, "c")
print(p.n, p[1], p[3])

local function withfixed(a, b, ...)
  return a, b, select("#", ...)
end
print(withfixed(1, 2, 3, 4, 5))

-- passing varargs along
local function passthru(...) return sum(...) end
print(passthru(5, 5, 5))

-- table.unpack
print(table.unpack({ 1, 2, 3 }))
local a, b, c = table.unpack({ "u", "v" })
print(a, b, c)

-- mixed: fixed params then varargs used in a table
local function tolist(prefix, ...)
  local t = { prefix }
  for i = 1, select("#", ...) do t[#t + 1] = (select(i, ...)) end
  return table.concat(t, "/")
end
print(tolist("p", 1, 2, 3))
