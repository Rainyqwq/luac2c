-- table library, sorting, unpack, OOP
local t = { 5, 2, 9, 1, 7 }
table.sort(t)
print(table.concat(t, ","))
table.sort(t, function(a, b) return a > b end)
print(table.concat(t, ","))

local mixed = { { k = "b" }, { k = "a" }, { k = "c" } }
table.sort(mixed, function(x, y) return x.k < y.k end)
print(mixed[1].k, mixed[3].k)

table.insert(t, 99)
table.insert(t, 1, 0)
print(table.concat(t, ","))
print(table.remove(t), table.remove(t, 1))
print(table.concat(t, ","))

print(table.unpack({ 1, 2, 3 }))
print(table.unpack({ 1, 2, 3 }, 2))
print(table.unpack({ 1, 2, 3 }, 2, 3))
print(table.pack(1, nil, 3).n)
local p = table.pack("a", "b")
print(p.n, p[1], p[2])

-- move
local src = { 1, 2, 3, 4, 5 }
local dst = {}
print(table.concat(table.move(src, 2, 4, 1, dst), ","))
print(table.concat(table.move(src, 1, 3, 3), ","))

-- OOP with colon + inheritance
local Animal = {}
Animal.__index = Animal
function Animal.new(name, sound)
  local o = { name = name, sound = sound }
  return setmetatable(o, Animal)
end
function Animal:speak() return self.name .. " says " .. self.sound end
function Animal:describe() return "Animal(" .. self.name .. ")" end

local Dog = setmetatable({}, { __index = Animal })
Dog.__index = Dog
function Dog.new(name) return setmetatable(Animal.new(name, "woof"), Dog) end
function Dog:describe() return "Dog(" .. self.name .. ")" end
function Dog:fetch(n) return self.name .. " fetched " .. n end

local a = Animal.new("cat", "meow")
local d = Dog.new("rex")
print(a:speak(), d:speak())
print(a:describe(), d:describe())
print(d:fetch(3))
print(getmetatable(d) == Dog, getmetatable(getmetatable(d)) == Animal)

-- counter closure with shared state
local function counter()
  local n = 0
  return function() n = n + 1; return n end,
         function() n = n - 1; return n end,
         function() return n end
end
local inc, dec, get = counter()
inc(); inc(); inc(); dec()
print(get(), inc())

-- accumulator style
local function acc(sum) return function(x) sum = sum + x; return sum end end
local A = acc(10)
print(A(1), A(2), A(3))

-- deep recursion
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fib(20))

-- memoized with table + closure
local function memo(f)
  local cache = {}
  return function(x)
    local v = cache[x]
    if v == nil then v = f(x); cache[x] = v end
    return v
  end
end
local calls = 0
local sq = memo(function(x) calls = calls + 1; return x * x end)
print(sq(4), sq(4), sq(5), calls)
print("oop-ok")
