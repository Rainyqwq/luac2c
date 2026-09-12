-- test_vargidx.lua -- probe every branch of OP_GETVARG's key handling:
--   integral index in range, out of range, zero, negative, the "n" key,
--   an integral *float* index (the VM's tointegerns accepts these), a
--   non-integral float, a numeric string, and a junk string.
local function vprobe(... v)
  local keys = {0, 1, 2, 3, 4, -1, "n", "x", 2.0, 3.0, 1.5, "2"}
  local r = {}
  for i = 1, #keys do
    r[i] = tostring(keys[i]) .. "=" .. tostring(v[keys[i]])
  end
  return table.concat(r, " ")
end

print("three:", vprobe(10, 20, 30))
print("none :", vprobe())
print("one  :", vprobe("a"))
