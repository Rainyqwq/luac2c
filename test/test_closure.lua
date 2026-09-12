-- closures over locals, shared upvalues, recursion
local function counter()
  local n = 0
  return function()
    n = n + 1
    return n
  end
end
local c1, c2 = counter(), counter()
print(c1(), c1(), c1())
print(c2())

local function adder(x)
  return function(y) return x + y end
end
print(adder(10)(5), adder(100)(5))

-- upvalue shared between two closures
local function pair()
  local v = 0
  return function() v = v + 1 end, function() return v end
end
local inc, get = pair()
inc(); inc()
print(get())

-- recursion + mutual recursion
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
print(fact(5))

local function iseven(n) if n == 0 then return true end return isodd(n - 1) end
function isodd(n) if n == 0 then return false end return iseven(n - 1) end
print(iseven(10), iseven(7))

-- deeply nested closures capturing at several levels
local function outer(a)
  return function(b)
    return function(c)
      return a + b + c
    end
  end
end
print(outer(1)(2)(3))

-- method style with colon and self
local obj = { value = 5 }
function obj:add(n) self.value = self.value + n end
function obj:get() return self.value end
obj:add(3)
print(obj:get())
print(obj.get(obj))
