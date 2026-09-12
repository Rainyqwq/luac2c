-- string library + patterns
print(("x"):rep(5), ("ab"):rep(3, "-"))
print(string.upper("aBc"), string.lower("XYz"))
print(("[%s]=%d"):format("k", 42))
print(string.format("%5.2f|%-6s|%06d|%x|%5.3s", 3.14159, "hi", 42, 255, "abcdef"))
print(#"hello", ("hello"):len())
print(("a,b,c"):sub(1, 3), ("hello"):sub(-3), ("hello"):sub(2, -2))
print(("hello"):byte(1, 2))
print(string.char(72, 105))
print(("  trim  "):match("^%s*(.-)%s*$") .. "|")

-- find / match with captures
print(("key=value"):find("(%w+)=(%w+)"))
print(("2026-09-11"):match("(%d+)-(%d+)-(%d+)"))
print(("hello world"):gsub("o", "0"))
print(("hello world"):gsub("(l)", "<%1>"))
print(("abc"):gsub("", "-"))

-- gmatch
local out = {}
for w in ("one two three"):gmatch("%a+") do out[#out + 1] = w end
print(table.concat(out, "/"))

local kv = {}
for k, v in ("a=1,b=2"):gmatch("(%w+)=(%w+)") do kv[#kv + 1] = k .. "->" .. v end
print(table.concat(kv, ";"))

-- gsub with function and table
print(("a1b2c3"):gsub("%d", function(d) return "[" .. d * 2 .. "]" end))
print(("abc"):gsub("%a", { a = "A", b = "B" }))

-- string table metatable usage
local s = "Hello"
print(s:upper(), s:reverse(), s:sub(2))
print(table.concat({ ("x"):rep(2), "y" }, "-"))

-- long strings and escapes
local long = [[line1
line2]]
print(#long, long:find("line2"))
print("tab\there\nnewline" == "tab\there\nnewline")

-- utf8-ish byte iteration
local bs = {}
for c in ("abc"):gmatch(".") do bs[#bs + 1] = c:byte() end
print(#bs, bs[1], bs[3])

-- tonumber / tostring
print(tonumber("42"), tonumber("0x1F"), tonumber("3.5"), tonumber("abc"))
print(tostring(10) == "10", tostring(1.0), tostring(nil))
print(string.format("%d %s", 10, 3.0))
print("string-ok")
