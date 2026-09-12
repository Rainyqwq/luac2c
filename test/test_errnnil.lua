-- test_errnnil.lua -- OP_ERRNNIL fidelity.
--
-- Note: using a 'global' declaration anywhere in a scope switches that scope
-- into strict mode, where every *read* of a global must also be declared.  So
-- the library names this file touches are declared up front.  A declaration
-- without '=' emits no check; only 'global name = value' emits OP_ERRNNIL.
global print, tostring, pcall, table

local seen = {}

-- first definition of 'gx' is fine
global gx = 111
seen[#seen + 1] = tostring(gx)

-- re-defining it must raise the VM's error, and be catchable
local ok, err = pcall(function()
  global gx = 222
end)
seen[#seen + 1] = "ok=" .. tostring(ok)
seen[#seen + 1] = (tostring(err):match("global '[^']*' already defined") or "NO-MATCH")

-- the original value must survive the failed re-definition
seen[#seen + 1] = tostring(gx)

-- a fresh name still works afterwards
global gy = 7
seen[#seen + 1] = tostring(gy)

print(table.concat(seen, " "))
