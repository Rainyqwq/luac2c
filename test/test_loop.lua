-- numeric for (integer and float), while, repeat, break
for i = 1, 5 do io.write(i, " ") end
print()
for i = 10, 1, -3 do io.write(i, " ") end
print()
for i = 1, 10, 3 do io.write(i, " ") end
print()
for x = 1.0, 2.0, 0.5 do io.write(x, " ") end
print()
for i = 1, 3 do
  if i == 2 then goto continue end
  io.write(i, " ")
  ::continue::
end
print()
local n = 0
while n < 5 do n = n + 1 end
print(n)
local m = 0
repeat
  m = m + 2
until m >= 6
print(m)
local s = 0
for i = 1, 10 do
  s = s + i
  if s > 20 then break end
end
print(s)
-- nested loops
for i = 1, 3 do
  for j = 1, i do io.write("*") end
  io.write("|")
end
print()
print(math.maxinteger // 1, math.mininteger // 1)
