-- Recursion / nesting hazard for the generic-for closing value: an inner
-- function with a *plain* generic for must not clear the outer loop's
-- "closing value is non-nil" state.
local events = {}
local function closer(tag)
  return setmetatable({}, { __close = function() events[#events+1] = "c:"..tag end })
end
local function plain()
  local s = 0
  for k, v in ipairs({1,2,3}) do s = s + v end   -- no 4th value
  return s
end
local function outer(d)
  for v in ("ab"):gmatch("."), nil, nil, closer("o"..d) do
    if d > 0 then outer(d - 1) else plain() end
  end
end
outer(2)
print(table.concat(events, ","))
