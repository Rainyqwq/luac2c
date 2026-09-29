-- registers reused across scopes + captures + weak tables
local weak = setmetatable({}, {__mode="k"})
do
  local a,b,c = 1,2,3
  for i=1,3 do
    local t = {i, i*2, i*3}
    weak[i] = t
    a = a + #t
  end
  print("a", a)
end
collectgarbage()
local n=0; for k,v in pairs(weak) do n=n+1 end
print("weak", n>=0)

-- nested closures over reused register
local fns = {}
for i=1,4 do
  local x = i*10
  fns[i] = function() return x end
end
local s=0; for _,f in ipairs(fns) do s=s+f() end
print("sum", s)

-- to-be-closed
do
  local closed = 0
  local function mk(n) return setmetatable({}, {__close=function() closed=closed+n end}) end
  do
    local _c1 <close> = mk(1)
    local _c2 <close> = mk(2)
  end
  print("closed", closed)
end
