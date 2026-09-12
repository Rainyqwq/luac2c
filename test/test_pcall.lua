-- pcall / error / xpcall / assert / select
-- NOTE: the C translation has no line info, so error messages are compared
-- after stripping the "file:line: " prefix and the debug-only
-- "(local 'x')" suffixes.  Everything else must match exactly.
local function norm(s)
  s = tostring(s)
  s = (s:gsub("^.-:%d+: ", ""))
  s = (s:gsub(" %(local '[^']*'%)", ""))
  s = (s:gsub(" %(global '[^']*'%)", ""))
  s = (s:gsub(" %(field '[^']*'%)", ""))
  s = (s:gsub(" %(method '[^']*'%)", ""))
  s = (s:gsub(" %(upvalue '[^']*'%)", ""))
  return s
end
local function P(ok, ...)
  if ok then return true, ... end
  return false, norm((...))
end

print(pcall(function() return 1, 2, 3 end))
print(P(pcall(function() error("boom") end)))
local ok, e = pcall(function() error({ code = 7 }, 0) end)
print(ok, type(e), e.code)
print(pcall(error))
print(P(pcall(function() error("lv2", 2) end)))

local ok, err = xpcall(function() error("x") end, function(m) return "H:" .. norm(m) end)
print(ok, err)

local trace = {}
local ok2 = xpcall(function() local t; return t.x end, function(m) trace[#trace + 1] = norm(m); return m end)
print(ok2, #trace, trace[1])

-- select
print(select("#"), select("#", nil, nil), select("#", 1, 2, 3))
print(select(1, "a", "b", "c"))
print(select(-1, "a", "b", "c"))
print(select(2, "a", "b", "c"))

-- assert
print(pcall(assert, false))
print(assert(1, "msg"))
local s, e2 = pcall(assert, nil, "custom")
print(s, e2)

-- error with non-string, level
local function inner() error("deep", 2) end
local function outer() inner() end
print(P(pcall(outer)))

-- nested pcall + varargs forwarding
local function protect(f, ...)
  return pcall(f, ...)
end
print(protect(function(a, b) return a + b end, 3, 4))
print(P(protect(function(a) return a.x end, nil)))

-- error in metamethod
local t = setmetatable({}, { __index = function() error("mm") end })
print(P(pcall(function() return t.x end)))

-- runtime error
local r1, r2 = pcall(function() return (nil) + 1 end)
print(r1, r2 ~= nil)

-- tostring of error objects
print(P(pcall(function() error(setmetatable({}, { __tostring = function() return "E!" end })) end)))
print("pcall-ok")
