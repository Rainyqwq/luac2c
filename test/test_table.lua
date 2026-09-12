-- table constructors, indexing, iteration, library
local t = { 10, 20, 30, x = 1, y = 2 }
print(#t, t[1], t[3], t.x, t.y)
t[4] = 40
t.z = 3
print(#t, t[4], t.z)

local nested = { a = { b = { c = 42 } } }
print(nested.a.b.c)

local big = {}
for i = 1, 100 do big[i] = i * i end
print(#big, big[10], big[100])

local sum = 0
for i, v in ipairs(big) do sum = sum + v end
print(sum)

local keys = {}
for k in pairs({ a = 1, b = 2, c = 3 }) do keys[#keys + 1] = k end
table.sort(keys)
print(table.concat(keys, ","))

print(table.concat({ "x", "y", "z" }, "-"))
table.insert(t, 99)
print(#t, t[#t])
print(table.remove(t))

local meta = {
  __add = function(l, r) return l.n + r.n end,
  __tostring = function(o) return "Obj(" .. o.n .. ")" end,
  __index = function(tb, k) return "missing:" .. k end,
}
local o1 = setmetatable({ n = 3 }, meta)
local o2 = setmetatable({ n = 4 }, meta)
print(o1 + o2)
print(tostring(o1))
print(o1.whatever)
