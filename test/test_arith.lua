-- arithmetic, bitwise, length, concat
local a, b = 7, 3
print(a + b, a - b, a * b, a / b, a // b, a % b, a ^ 2)
print(-a, a // -b, 7 % -3)
print(1.5 + 2, 1.5 * 4, 7 / 2, 2 ^ 0.5)
print(6 & 3, 6 | 3, 6 ~ 3, ~0, 1 << 4, 256 >> 4)
print(#"hello", #{ 1, 2, 3 })
print("a" .. "b" .. 1 .. 2.0)
print(math.type(1), math.type(1.0), math.type("1"))
print(3 == 3.0, "3" == 3)
print(1 < 2, 2 <= 2, 3 > 4, 4 >= 4, 1 ~= 2)
local x = 10
x = x + 1
print(x)
