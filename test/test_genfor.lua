-- Generic 'for' with a 4th (to-be-closed) control value.  OP_TFORPREP must mark
-- that slot as to-be-closed, otherwise __close never runs.
local events = {}
local function closer(tag)
  return setmetatable({}, {
    __close = function() events[#events + 1] = "close:" .. tag end,
  })
end
local function make(n)
  local i = 0
  return function() i = i + 1; if i <= n then return i end end
end

for v in make(3), nil, nil, closer("g") do
  events[#events + 1] = "v" .. v
end
print(table.concat(events, ","))

-- plain generic for (no closing value) must be unaffected
events = {}
for k, v in ipairs({ 10, 20 }) do events[#events + 1] = k .. "=" .. v end
print(table.concat(events, ","))

-- nested to-be-closed locals still close innermost-first
events = {}
do
  local a <close> = closer("a")
  do
    local b <close> = closer("b")
    events[#events + 1] = "body"
  end
  events[#events + 1] = "after-inner"
end
print(table.concat(events, ","))
