-- Immediate comparisons: the sB immediate must keep its original numeric
-- *type* when a metamethod is invoked, matching op_orderI's 'isf' flag.
local seen = {}
local function record(a, b)
  seen[#seen + 1] = tostring(math.type(a)) .. "/" .. tostring(math.type(b))
  return false
end
local x = setmetatable({}, { __lt = record, __le = record })

local function probe(label, v) print(label, v, seen[#seen]) end

probe("x<2.0  ", x < 2.0)    -- __lt(x, 2.0)  -> table/float
probe("x<=3.0 ", x <= 3.0)   -- __le(x, 3.0)  -> table/float
probe("4.0>x  ", 4.0 > x)    -- __lt(4.0, x)  -> float/table
probe("5.0>=x ", 5.0 >= x)   -- __le(5.0, x)  -> float/table
probe("x<2    ", x < 2)      -- __lt(x, 2)    -> table/integer
probe("x<=3   ", x <= 3)     -- __le(x, 3)    -> table/integer
probe("4>x    ", 4 > x)      -- __lt(4, x)    -> integer/table
probe("5>=x   ", 5 >= x)     -- __le(5, x)    -> integer/table

-- pure numeric paths must stay exact
print(1 < 2, 2.5 < 3, 2.0 <= 2, 3 >= 3.0)
print(1 == 1, 1 == 1.0, 1.0 == 1, 2 == 3)
