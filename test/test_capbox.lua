-- Captured registers live in two places: the stack slot and, once a closure has
-- touched it, the shared cell.  The refresh from cell to slot is emitted only
-- where a captured register is actually read, so these are the shapes that have
-- to keep working: a closure that writes, one that reads, both interleaved,
-- and the same register captured at two nesting levels.
local out = {}

-- 1. closure writes, outer reads afterwards
do
  local n = 0
  local function set(v) n = v end
  set(7)
  out[#out + 1] = "w1=" .. n
  set(n * 2)
  out[#out + 1] = "w2=" .. n
end

-- 2. outer writes, closure reads
do
  local s = "a"
  local function get() return s end
  out[#out + 1] = "r1=" .. get()
  s = s .. "b"
  out[#out + 1] = "r2=" .. get()
end

-- 3. interleaved across a loop: the slot must be refreshed every iteration
do
  local acc = 0
  local function add(v) acc = acc + v end
  for i = 1, 5 do
    add(i)
    if acc % 2 == 0 then add(10) end
    out[#out + 1] = tostring(acc)
  end
end

-- 4. two levels of nesting on the same register
do
  local v = 1
  local function mid()
    local function inner() v = v + 1 end
    inner()
    return v
  end
  out[#out + 1] = "n1=" .. mid()
  out[#out + 1] = "n2=" .. v
  v = 100
  out[#out + 1] = "n3=" .. mid()
end

-- 5. captured register read only inside the closure, never outside
do
  local hidden = 5
  local function peek() return hidden * 3 end
  local t = 0
  for _ = 1, 4 do t = t + peek() end
  out[#out + 1] = "h=" .. t
end

-- 6. recursion: a nested call must not disturb the outer frame's cells
do
  local depth = 0
  local function rec(d)
    local seen = depth
    if d > 0 then rec(d - 1) end
    return seen
  end
  depth = 42
  out[#out + 1] = "rec=" .. rec(3)
end

print(table.concat(out, ","))
