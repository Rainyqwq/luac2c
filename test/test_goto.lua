-- goto / label / break / nested loops
local function t1()
  local i = 1
  ::top::
  i = i + 1
  if i < 5 then goto top end
  return i
end
print(t1())

-- goto forward out of nested loop
local function t2()
  local out = 0
  for i = 1, 5 do
    for j = 1, 5 do
      if i * j > 6 then out = i * 10 + j; goto done end
    end
  end
  ::done::
  return out
end
print(t2())

-- break inside nested while + repeat
local function t3()
  local s = 0
  local i = 0
  while true do
    i = i + 1
    local j = 0
    repeat
      j = j + 1
      if i + j > 4 then break end
      s = s + i * j
    until j > 10
    if i > 3 then break end
  end
  return s
end
print(t3())

-- goto backwards across closure boundary
local function t4()
  local n = 0
  local f
  ::again::
  n = n + 1
  f = function() return n end
  if n < 3 then goto again end
  return f()
end
print(t4())

-- goto into a block that defines locals (needs close)
local function t5()
  local r
  do
    local x = 10
    r = x * 2
    goto out
  end
  ::out::
  return r
end
print(t5())

-- numeric for with break and goto continue emulation
local function t6()
  local sum = 0
  for i = 1, 10 do
    if i % 2 == 0 then goto cont end
    sum = sum + i
    ::cont::
  end
  return sum
end
print(t6())
print("goto-ok")
