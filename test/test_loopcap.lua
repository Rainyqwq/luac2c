-- Per-iteration upvalue capture, and the OP_CLOSE that makes it work.
--
-- A numeric 'for' variable is a fresh local on every turn, so each closure
-- made inside the loop must capture its own upvalue.  The compiler implements
-- this by emitting CLOSE after the body's last capture of the slot; the VM's
-- luaF_close() then ends the upvalue's life, and the next turn's CLOSURE
-- captures a new one.
--
-- When luac2c's OP_CLOSE handler ignored upvalues (it only closed
-- to-be-closed slots), all turns aliased one shared cell.  Every closure then
-- read the final value of i -- and because the register was also a *cache*
-- refreshed from that cell, the loop's own reads were wrong too, which is how
-- the failure showed up as "attempt to call a nil value" rather than a wrong
-- number.  These cases pin both halves down.

local function join(t, sep)
  local r = {}
  for i = 1, #t do r[i] = tostring(t[i]) end
  return table.concat(r, sep or ",")
end

-- 1. capture the loop variable itself
local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
print(join{fs[1](), fs[2](), fs[3]()})          -- 1,2,3

-- 2. the loop body still reads the current value, not a stale/final one
local sums = {}
local acc = 0
for i = 1, 4 do
  acc = acc + i
  sums[i] = function() return i * 10 end
end
print(acc, join{sums[1](), sums[4]()})          -- 10 10,40

-- 3. two closures per turn share that turn's cell
--    (the loop variable itself is const in 5.5, so use a per-turn local)
local pairs_tbl = {}
for i = 1, 3 do
  local cell = i + 1000
  local getter = function() return cell end
  local setter = function(v) cell = v end
  pairs_tbl[i] = {getter, setter}
end
pairs_tbl[2][2](99)
print(pairs_tbl[1][1](), pairs_tbl[2][1](), pairs_tbl[3][1]())  -- 1001,99,1003

-- 4. a per-turn local is isolated the same way
local gs = {}
for i = 1, 3 do
  local v = i * 10
  gs[i] = function(x) if x then v = x end return v end
end
gs[1](100)
print(gs[1](), gs[2](), gs[3]())                -- 100,20,30

-- 5. nested loops: the inner variable restarts every outer turn
local grid = {}
for i = 1, 2 do
  for j = 1, 2 do grid[#grid + 1] = function() return i * 10 + j end end
end
print(join{grid[1](), grid[2](), grid[3](), grid[4]()})  -- 11,12,21,22

-- 6. a while loop's local is also per-turn
local hs = {}
local k = 1
while k <= 3 do
  local w = k * 100
  hs[k] = function() return w end
  k = k + 1
end
print(join{hs[1](), hs[2](), hs[3]()})          -- 100,200,300

-- 7. the closed cell survives the loop ending
local last
for i = 1, 3 do last = function() return i end end
print(last())                                   -- 3

-- 8. capturing inside a repeat loop
local rs = {}
local n = 0
repeat
  n = n + 1
  local v = n + 100
  rs[n] = function() return v end
until n >= 3
print(join{rs[1](), rs[2](), rs[3]()})          -- 101,102,103

-- 9. closures over the loop variable in a generic for
local ps = {}
for _, ch in ipairs{"a", "b", "c"} do
  ps[#ps + 1] = function() return ch end
end
print(join{ps[1](), ps[2](), ps[3]()})          -- a,b,c
