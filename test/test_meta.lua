-- metatables & metamethods
local mt = {
  __index = function(t, k) return "idx:" .. k end,
  __add = function(a, b) return "add(" .. a.n .. "," .. (type(b) == "table" and b.n or b) .. ")" end,
  __tostring = function(t) return "Obj(" .. t.n .. ")" end,
  __len = function(t) return t.n end,
  __eq = function(a, b) return a.n == b.n end,
  __lt = function(a, b) return a.n < b.n end,
  __call = function(self, x) return self.n + x end,
  __concat = function(a, b) return "(" .. tostring(a) .. "|" .. tostring(b) .. ")" end,
  __unm = function(a) return setmetatable({ n = -a.n }, getmetatable(a)) end,
}
mt.__name = "MyType"

local function new(n) return setmetatable({ n = n }, mt) end

local a = new(3)
local b = new(4)
print(a.missing)
print(a + b)
print(tostring(a))
print(#a)
print(a == new(3), a == b)
print(a < b, b < a)
print(a(100))
print(a .. b)
print(-a)

-- __newindex + rawget/rawset
local log = {}
local proxy = setmetatable({}, {
  __index = function(t, k) return rawget(t, k) or "def" end,
  __newindex = function(t, k, v) log[#log + 1] = k; rawset(t, k, v) end,
})
proxy.x = 1
proxy.y = 2
print(proxy.x, proxy.y, proxy.z)
print(table.concat(log, ","))
print(rawget(proxy, "x"), rawget(proxy, "zz"))

-- inheritance chain
local Base = {}
Base.__index = Base
function Base:new(o) o = o or {}; setmetatable(o, self); return o end
function Base:who() return "base:" .. self.name end
function Base:val() return 1 end

local Derived = setmetatable({}, { __index = Base })
Derived.__index = Derived
function Derived:who() return "derived:" .. self.name end
function Derived:val() return Base.val(self) + 10 end

local d = Derived:new({ name = "d" })
print(d:who(), d:val(), Base.who(d))

-- __gc-free: __close / to-be-closed
do
  local closed = {}
  local function mkcloser(tag)
    return setmetatable({}, { __close = function() closed[#closed + 1] = tag end })
  end
  do
    local c1 <close> = mkcloser("A")
    local c2 <close> = mkcloser("B")
    print("in scope")
  end
  print(table.concat(closed, ","))
end

-- metamethod on string via string library metatable
local smt = getmetatable("")
print(type(smt), smt ~= nil and smt.__index == string)

-- rawequal / rawlen
print(rawequal(a, a), rawequal(new(1), new(1)), rawlen({ 1, 2, 3 }))
print("meta-ok")
