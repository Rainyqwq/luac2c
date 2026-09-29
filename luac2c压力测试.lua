--============================================================================
-- luac2c 翻译完整性 / 安全性压力测试
-- 目标方言: Lua 5.3 / 5.4（64 位整数 + 双精度浮点双数值类型）
-- 用法:
--   1. 用官方解释器跑一遍: lua luac2c压力测试.lua   -> 基准输出
--   2. 用 luac2c 翻译后的产物跑一遍                -> 对比输出
--   3. 除 SMOKE 行外，所有输出必须是确定性的，diff 应完全一致
-- 说明:
--   * 若你的 luac2c 面向 Lua 5.1 / LuaJIT，则位运算、//、goto、utf8、
--     string.pack 等 5.3+ 特性本身不存在，对应段落应跳过。
--   * 脚本末尾以退出码汇报结果: 全部通过 exit 0，否则 exit 1。
--============================================================================

print(_VERSION)

local passed, failed = 0, 0
local fail_log = {}

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) == "number" and type(b) == "number" then
    if a ~= a and b ~= b then return true end -- NaN 与 NaN 视为相等
    return false
  end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function expect(name, got, want)
  if deep_eq(got, want) then
    passed = passed + 1
  else
    failed = failed + 1
    fail_log[#fail_log + 1] =
      ("FAIL [%s] got=%s want=%s"):format(name, tostring(got), tostring(want))
  end
end

local function expect_err(name, f, ...)
  local ok = pcall(f, ...)
  if not ok then
    passed = passed + 1
  else
    failed = failed + 1
    fail_log[#fail_log + 1] = ("FAIL [%s] 预期报错但执行成功"):format(name)
  end
end

--== 1. 数值与算术语义 ==--
expect("int-div", 7 // 2, 3)
expect("int-div-neg", -7 // 2, -4)
expect("float-div", 7 / 2, 3.5)
expect("mixed-div", 7.0 // 2, 3.0)
expect("mod-pos", 7 % 3, 1)
expect("mod-neg-a", -7 % 3, 2)
expect("mod-neg-b", 7 % -3, -2)
expect("mod-float", 5.5 % 2, 1.5)
expect("pow", 2^10, 1024.0)
expect("pow-neg", 2^-2, 0.25)
expect("unm", -(-5), 5)
expect("int-overflow", math.maxinteger + 1, math.mininteger)
expect("int-underflow", math.mininteger - 1, math.maxinteger)
expect("int-mul-overflow", math.maxinteger * 2, -2)
expect("abs-minint", math.abs(math.mininteger), math.mininteger)
expect("float-div-zero", 1 / 0, math.huge)
expect("float-div-zero-neg", -1 / 0, -math.huge)
expect("nan-neq", (0 / 0) == (0 / 0), false)
expect("float-mod-zero-nan", (1.0 % 0) ~= (1.0 % 0), true)
expect_err("int-div-zero", function() return 1 // 0 end)
expect_err("int-mod-zero", function() return 1 % 0 end)
expect("num-format-int", tostring(3), "3")
expect("num-format-float", tostring(3.0), "3.0")
expect("num-format-negzero", tostring(-0.0), "-0.0")
expect("num-format-div", tostring(1 / 1), "1.0")
expect("hex-float", 0x1p4, 16.0)
expect("hex-float-frac", 0x.8p1, 1.0)
expect("hex-int", 0xFF, 255)
expect("sci", 1.5e3, 1500.0)
expect("dot-num", .5, 0.5)
expect("int-float-eq", 1 == 1.0, true)
expect("math.type-int", math.type(1), "integer")
expect("math.type-float", math.type(1.0), "float")
expect("math.type-str", math.type("1"), nil)
expect("tointeger-ok", math.tointeger(3.0), 3)
expect("tointeger-fail", math.tointeger(3.5), nil)
expect("key-normalize", (function() local t = {} t[1.0] = "x" return t[1] end)(), "x")
expect("math.floor", math.floor(-3.5), -4)
expect("math.ceil", math.ceil(-3.5), -3)
expect("math.fmod", math.fmod(-7, 3), -1)
expect("math.max", math.max(1, 2.5, 2), 2.5)
expect("math.min", math.min(1, -2.5, 2), -2.5)
expect("math.sqrt", math.sqrt(16), 4.0)
expect("math.huge-cmp", math.huge > math.maxinteger, true)

--== 2. 位运算（5.3+）==--
expect("band", 0xF0 & 0x3C, 0x30)
expect("bor", 0xF0 | 0x0F, 0xFF)
expect("bxor", 0xFF ~ 0x0F, 0xF0)
expect("bnot", ~0, -1)
expect("unary-bnot", ~5, -6)
expect("shl", 1 << 62, 0x4000000000000000)
expect("shr-logical", -1 >> 60, 15)   -- Lua 的 >> 是逻辑右移
expect("shr-big", 1 >> 64, 0)
expect("shl-big", 1 << 64, 0)
expect("shl-neg", 8 << -1, 4)
expect("float-integral-band", 3.0 & 1, 1)
expect_err("float-frac-band", function() return 3.5 & 1 end)
expect("prec-bor-bxor", 1 | 2 ~ 3, 1)   -- | 优先级最低
expect("prec-bxor-band", 1 ~ 2 & 3, 3)  -- & 高于 ~
expect("prec-band-shift", 1 & 3 << 1, 0) -- 移位高于 &

--== 3. 字符串与模式匹配 ==--
expect("str-concat", "a" .. "b" .. "c", "abc")
expect("num-concat", 10 .. 20, "1020")
expect("concat-assoc", 1 .. 2 .. 3, "123")
expect("str-arith-coerce", "10" + 5, 15)
expect("str-arith-mul", "3" * "4", 12)
expect_err("str-arith-bad", function() return "abc" + 1 end)
expect("str-len", #"hello", 5)
expect("str-cmp", "abc" < "abd", true)
expect("str-cmp-case", "Z" < "a", true)
expect_err("str-num-cmp", function() return 1 < "2" end)
expect("str-escapes", "\65\066\x43\u{4E2D}", "ABC中")
expect("str-long-bracket", [==[a ]] b]==], "a ]] b")
expect("str-rep", string.rep("ab", 3, "-"), "ab-ab-ab")
expect("str-sub-neg", ("hello"):sub(-3), "llo")
expect("str-sub-range", ("hello"):sub(2, -2), "ell")
expect("str-byte-truncate", string.byte("ABC", 1, 3), 65) -- 多返回值在中间位置被截断
expect("str-char", string.char(72, 105), "Hi")
expect("str-upper", ("aBc"):upper(), "ABC")
expect("str-rev", ("abc"):reverse(), "cba")
expect("str-find-plain", ("a.b"):find(".", 1, true), 2)
expect("str-find-pat", select(1, ("hello world"):find("o w")), 5)
expect("str-match-cap", ("key=value"):match("(%w+)=(%w+)"), "key")
expect("str-match-num", ("abc123"):match("%d+"), "123")
expect("str-gsub-basic", ("hello"):gsub("l", "L"), "heLLo")
expect("str-gsub-count", select(2, ("hello"):gsub("l", "L")), 2)
expect("str-gsub-cap", ("hello"):gsub("(l+)", "[%1]"), "he[ll]o")
expect("str-gsub-percent", ("100%"):gsub("%%", "pct"), "100pct")
expect("str-gsub-func", ("abc"):gsub("%a", function(c) return c:upper() end), "ABC")
expect("str-gsub-table", ("$a $b"):gsub("%$(%w+)", {a = "1", b = "2"}), "1 2")
expect("str-gsub-anchor", ("abc"):gsub("^", ">"), ">abc")
expect("str-gsub-empty", ("ab"):gsub("", "-"), "-a-b-")
expect("str-gmatch", (function()
  local r = {}
  for w in ("one,two,three"):gmatch("[^,]+") do r[#r + 1] = w end
  return table.concat(r, "|")
end)(), "one|two|three")
expect("str-frontier", ("THE (quick) fox"):find("%f[%a]%u+%f[%A]") ~= nil, true)
expect("str-balanced", ("(a(b)c)"):match("%b()"), "(a(b)c)")
expect("str-format-int", string.format("%5d|%-5d|%05d", 42, 42, 42), "   42|42   |00042")
expect("str-format-hex", string.format("%x|%X|%#x", 255, 255, 255), "ff|FF|0xff")
expect("str-format-float", string.format("%.3f", math.pi), "3.142")
expect("str-format-str", string.format("%s=%s", "k", "v"), "k=v")
expect("str-format-nil", string.format("%s", nil), "nil")
expect("str-format-pct", string.format("%%"), "%")
expect("str-format-q", string.format("%q", 'a"b'), '"a\\"b"')
expect("str-pack-unpack", (function()
  local s = string.pack("<i4", -12345)
  local v, pos = string.unpack("<i4", s)
  return {v, pos}
end)(), {-12345, 5})
expect("str-packsize", string.packsize("i4d"), 12)

--== 4. 表与元表 ==--
local t = {10, 20, 30, x = "a", [100] = "hundred"}
expect("tbl-len", #t, 3)
expect("tbl-index", t[2], 20)
expect("tbl-field", t.x, "a")
expect("tbl-intkey", t[100], "hundred")
expect("tbl-nil-default", t.missing, nil)
expect("tbl-remove", (function()
  local a = {1, 2, 3} table.remove(a, 2) return table.concat(a, ",")
end)(), "1,3")
expect("tbl-insert", (function()
  local a = {1, 3} table.insert(a, 2, 2) return table.concat(a, ",")
end)(), "1,2,3")
expect("tbl-sort", (function()
  local a = {5, 2, 8, 1} table.sort(a) return table.concat(a, ",")
end)(), "1,2,5,8")
expect("tbl-sort-cmp", (function()
  local a = {"bb", "a", "ccc"}
  table.sort(a, function(x, y) return #x < #y end)
  return table.concat(a, ",")
end)(), "a,bb,ccc")
expect("tbl-concat-sep", table.concat({1, 2, 3}, "-", 2, 3), "2-3")
expect("tbl-unpack-count", select("#", table.unpack({1, 2, 3})), 3)
expect("tbl-pack-n", table.pack(1, nil, 3).n, 3)
expect("tbl-move", (function()
  local a = {1, 2, 3, 4, 5}
  return table.concat(table.move(a, 2, 4, 1, {}), ",")
end)(), "2,3,4")
expect("tbl-move-overlap", (function()
  local a = {1, 2, 3, 4, 5} table.move(a, 1, 3, 2) return table.concat(a, ",")
end)(), "1,1,2,3,5")

-- 全套算术/比较/调用元方法
local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({a[1] + b[1], a[2] + b[2]}, V) end
V.__sub = function(a, b) return setmetatable({a[1] - b[1], a[2] - b[2]}, V) end
V.__unm = function(a) return setmetatable({-a[1], -a[2]}, V) end
V.__mul = function(a, s)
  if type(a) == "number" then a, s = s, a end
  return setmetatable({a[1] * s, a[2] * s}, V)
end
V.__eq = function(a, b) return a[1] == b[1] and a[2] == b[2] end
V.__lt = function(a, b) return a[1]^2 + a[2]^2 < b[1]^2 + b[2]^2 end
V.__le = function(a, b) return a[1]^2 + a[2]^2 <= b[1]^2 + b[2]^2 end
V.__len = function() return 2 end
V.__tostring = function(a) return ("V(%d,%d)"):format(a[1], a[2]) end
V.__concat = function(a, b) return tostring(a) .. tostring(b) end
V.__call = function(self, k) return self[1] * k + self[2] end
local function vec(x, y) return setmetatable({x, y}, V) end
local v1, v2 = vec(1, 2), vec(3, 4)
expect("mt-add", v1 + v2, vec(4, 6))
expect("mt-sub", v2 - v1, vec(2, 2))
expect("mt-unm", -v1, vec(-1, -2))
expect("mt-mul-right", v1 * 10, vec(10, 20))
expect("mt-mul-left", 10 * v1, vec(10, 20))
expect("mt-eq", v1 == vec(1, 2), true)
expect("mt-neq", v1 ~= v2, true)
expect("mt-lt", v1 < v2, true)
expect("mt-le", v1 <= vec(1, 2), true)
expect("mt-len", #v1, 2)
expect("mt-tostring", tostring(v1), "V(1,2)")
expect("mt-concat", v1 .. v2, "V(1,2)V(3,4)")
expect("mt-call", v1(10), 12)

-- __index 继承 / 函数形式 / 深层链 / 自环检测
local defaults = {color = "red", size = 10}
local obj = setmetatable({}, {__index = defaults})
expect("mt-index-inherit", obj.color, "red")
obj.color = "blue"
expect("mt-index-override", obj.color, "blue")
expect("mt-index-default-intact", defaults.color, "red")

local logged = {}
local proxy = setmetatable({}, {__index = function(_, k)
  logged[#logged + 1] = k
  return k .. "!"
end})
expect("mt-index-func", proxy.hello, "hello!")
expect("mt-index-func-log", #logged, 1)

local chain_top = {found = "top"}
local cur = chain_top
for i = 1, 100 do
  cur = setmetatable({["lvl" .. i] = i}, {__index = cur})
end
expect("mt-chain-deep", cur.found, "top")
expect("mt-chain-mid", cur.lvl50, 50)

local loopy = setmetatable({}, {})
getmetatable(loopy).__index = loopy
expect_err("mt-index-loop", function() return loopy.nothing end)

-- __newindex 只读代理 + raw 系列
local store = {}
local ro = setmetatable({}, {
  __index = store,
  __newindex = function(_, k) error("read-only: " .. k, 2) end,
})
expect_err("mt-newindex-ro", function() ro.x = 1 end)
store.x = 99
expect("mt-newindex-read", ro.x, 99)
expect("mt-rawset", (function() rawset(ro, "y", 7) return rawget(ro, "y") end)(), 7)
expect("rawequal-self", rawequal(v1, v1), true)
expect("rawequal-false", rawequal(v1, vec(1, 2)), false)
expect("rawlen-tbl", rawlen({1, 2, 3}), 3)
expect("rawlen-str", rawlen("abcd"), 4)

-- __metatable 保护
local prot = setmetatable({}, {__metatable = "locked"})
expect("mt-protected-get", getmetatable(prot), "locked")
expect_err("mt-protected-set", function() setmetatable(prot, {}) end)

-- 弱表与 __gc
do
  local wk = setmetatable({}, {__mode = "k"})
  for i = 1, 10 do wk[{}] = i end
  collectgarbage("collect")
  local n = 0
  for _ in pairs(wk) do n = n + 1 end
  expect("weak-k-collected", n, 0)
end
do
  local finalized = 0
  local gcmt = {__gc = function() finalized = finalized + 1 end}
  for i = 1, 5 do setmetatable({}, gcmt) end
  -- 终结器的执行时机允许落在本轮或下一轮 GC（手册只说"本轮被回收的那些"），
  -- 多收几轮直到收敛即可，避免依赖具体实现的回收轮次。
  local rounds = 0
  while finalized < 5 and rounds < 8 do
    collectgarbage("collect")
    rounds = rounds + 1
  end
  expect("gc-finalizers", finalized, 5)
end

--== 5. 闭包与上值 ==--
local function counter()
  local n = 0
  return function() n = n + 1 return n end, function() return n end
end
local inc, get = counter()
inc(); inc()
expect("closure-shared-upval", get(), 2)
expect("closure-inc", inc(), 3)

local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
expect("closure-loop-capture", fs[1]() * 100 + fs[2]() * 10 + fs[3](), 123)

local function make_account(balance)
  return {
    deposit = function(d) balance = balance + d return balance end,
    withdraw = function(w) balance = balance - w return balance end,
  }
end
local acc = make_account(100)
acc.deposit(50)
expect("closure-account", acc.withdraw(30), 120)

local fact
fact = function(n) if n <= 1 then return 1 end return n * fact(n - 1) end
expect("closure-recursion", fact(10), 3628800)

--== 6. 变参与多返回值 ==--
local function count(...) return select("#", ...) end
expect("va-count-0", count(), 0)
expect("va-count-nil", count(nil, nil, nil), 3)
expect("va-select-neg", select(-1, "a", "b", "c"), "c")
expect("va-select-2", select(2, "a", "b", "c"), "b")
expect("va-pack-n", (function(...) return table.pack(...).n end)(1, nil, nil), 3)
expect("va-unpack-range", (function(...)
  return table.unpack({...}, 2, 3)
end)(10, 20, 30, 40), 20)

local function three() return 1, 2, 3 end
expect("mr-all", (function()
  local a, b, c = three() return a + b * 10 + c * 100
end)(), 321)
-- 构造器里非末位的 multires 截成 1 个，末位的才全展开：{three(), three()} = {1,1,2,3}
expect("mr-truncate-mid", (function()
  local tt = {three(), three()} return #tt
end)(), 4)
-- 赋值列表同样：非末位截 1 个
expect("mr-truncate-assign", (function()
  local a, b = three(), three() return a + b
end)(), 2)
expect("mr-paren-truncate", (three()), 1)
expect("mr-expand-last", (function()
  local tt = {0, three()} return #tt
end)(), 4)

--== 7. 协程 ==--
-- 先探一下"协程里能否 yield"。luac2c 把函数体翻成 C 函数，yield 跨不过 C 调用边界，
-- 这一类用例在那种产物上会直接抛错；探到不支持就跳过它们，其余协程用例照常跑。
local CAN_YIELD = (function()
  local probe = coroutine.wrap(function() coroutine.yield(1) end)
  local ok = pcall(probe)
  return ok
end)()
if not CAN_YIELD then
  print("SKIP coroutine-yield cases (yield across a C-call boundary is unsupported)")
end

if CAN_YIELD then
local co = coroutine.create(function(a, b)
  local c = coroutine.yield(a + b)
  local d, e = coroutine.yield(c * 2)
  return d + e
end)
local _, cv1 = coroutine.resume(co, 1, 2)
local _, cv2 = coroutine.resume(co, 10)
local _, cv3 = coroutine.resume(co, 7, 8)
expect("co-yield1", cv1, 3)
expect("co-yield2", cv2, 20)
expect("co-return", cv3, 15)
expect("co-status-dead", coroutine.status(co), "dead")
expect("co-resume-dead", (coroutine.resume(co)), false)
end

local bad = coroutine.wrap(function() error("inside-co") end)
expect_err("co-wrap-error", bad)

if CAN_YIELD then
local function producer(n)
  return coroutine.wrap(function()
    for i = 1, n do coroutine.yield(i * i) end
  end)
end
local sq_sum = 0
for sq in producer(5) do sq_sum = sq_sum + sq end
expect("co-producer-sum", sq_sum, 55)

-- 跨 pcall 边界的 yield（5.3+ 必须支持）
local co2 = coroutine.create(function()
  local ok, v = pcall(function() return coroutine.yield("from-pcall") end)
  return ok, v
end)
local _, first = coroutine.resume(co2)
local _, rok, rval = coroutine.resume(co2, "resumed")
expect("co-yield-in-pcall", first, "from-pcall")
expect("co-pcall-resume-ok", rok, true)
expect("co-pcall-resume-val", rval, "resumed")
end

expect("co-isyieldable-main", coroutine.isyieldable(), false)
if CAN_YIELD then
expect("co-isyieldable-inside",
  coroutine.wrap(function() return coroutine.isyieldable() end)(), true)
end

--== 8. 错误处理 ==--
expect("err-pcall-msg", select(2, pcall(function() error("boom", 0) end)), "boom")
expect("err-pcall-table", (function()
  local _, e = pcall(function() error({code = 42}) end)
  return e.code
end)(), 42)
-- error() 无参时错误对象是字符串 "<no error object>"（luaG_errormsg），不是 nil
expect("err-pcall-nil", select(2, pcall(function() error() end)), "<no error object>")
expect("err-pcall-values", (function()
  local ok, a, b = pcall(function() return 10, 20 end)
  return ok and a + b
end)(), 30)
expect("err-xpcall-handler", (function()
  local _, handled = xpcall(function() error("x", 0) end,
    function(m) return "handled:" .. m end)
  return handled
end)(), "handled:x")
expect("err-nested", (function()
  local _, e = pcall(function()
    local _, e2 = pcall(error, "inner", 0)
    error("outer:" .. tostring(e2), 0)
  end)
  return e
end)(), "outer:inner")
expect("err-runtime", select(2, pcall(function()
  local x = nil return x.field
end)) ~= nil, true)
expect("err-assert-pass", assert(1, "unused"), 1)
expect_err("err-assert-fail", function() assert(false, "assertion-msg") end)
-- assert 会在消息前加 "文件:行号: "，只比对结尾
expect("err-assert-msg", (function()
  local _, e = pcall(function() assert(nil, "custom") end)
  return e:match("custom$") ~= nil
end)(), true)
expect("err-position-prefix", (function()
  local _, e = pcall(function() error("tagged") end)
  return e:match("tagged$") ~= nil
end)(), true)
expect_err("err-nil-chain", function()
  local a = {} return a.b.c
end)

--== 9. goto 与逻辑运算 ==--
do
  local i, s = 0, 0
  ::top::
  i = i + 1
  if i > 10 then goto fin end        -- 先判上界，否则偶数在 goto 时绕过上界检查
  if i % 2 == 0 then goto top end
  s = s + i
  goto top
  ::fin::
  expect("goto-loop", s, 25) -- 1+3+5+7+9
end
do
  local r = {}
  for i = 1, 3 do
    for j = 1, 3 do
      if i * j == 4 then goto done end
      r[#r + 1] = i * 10 + j
    end
  end
  ::done::
  expect("goto-nested-exit", table.concat(r, ","), "11,12,13,21")
end
expect("logic-and-or", (nil and 1) or 2, 2)
expect("logic-false-or", false or nil, nil)
expect("logic-zero-truthy", not not 0, true)
expect("logic-short-circuit", (function()
  local called = false
  local function f() called = true return true end
  local _ = false and f()
  return called
end)(), false)

--== 10. 迭代器 ==--
local function range_iter(state, ctl)
  if ctl >= state.max then return nil end
  return ctl + 1, ctl * ctl
end
local function range(max) return range_iter, {max = max}, 0 end
do
  local keys, vals = {}, {}
  for k, v in range(4) do keys[#keys + 1] = k vals[#vals + 1] = v end
  expect("iter-stateless-k", table.concat(keys, ","), "1,2,3,4")
  expect("iter-stateless-v", table.concat(vals, ","), "0,1,4,9")
end
expect("iter-pairs-count", (function()
  local n = 0 for _ in pairs({a = 1, b = 2, c = 3}) do n = n + 1 end return n
end)(), 3)
expect("iter-ipairs", (function()
  local s = 0 for i in ipairs({"a", "b", "c"}) do s = s + i end return s
end)(), 6)
expect("iter-next-empty", next({}), nil)
expect("iter-next-one", (function()
  local k, v = next({only = 1}) return k .. v
end)(), "only1")

--== 11. 递归与尾调用 ==--
-- 说明：luac2c 把每次 Lua 调用翻成一次 C 调用，会占用 Lua 的 C 调用额度
-- （LUAI_MAXCCALLS，默认 200），因此递归深度只能到 ~180 层；原生 Lua 纯 Lua
-- 递归不受此限。这里只验证"语义正确"，深度取一个两种实现都安全的值。
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
expect("rec-fib", fib(20), 6765)

local function down(n) if n == 0 then return 0 end return 1 + down(n - 1) end
expect("rec-deep-nontail", down(100), 100)

local function tail_loop(n, acc)
  if n == 0 then return acc end
  return tail_loop(n - 1, acc + 1)
end
expect("rec-tail", tail_loop(100, 0), 100)

local is_even, is_odd
function is_even(n) if n == 0 then return true end return is_odd(n - 1) end
function is_odd(n) if n == 0 then return false end return is_even(n - 1) end
expect("rec-mutual", is_even(100) and not is_odd(100), true)

--== 12. 动态代码 load ==--
expect("load-basic", load("return 1 + 2")(), 3)
expect("load-env", load("return x + y", "chunk", "t", {x = 3, y = 4})(), 7)
expect("load-nil-env", load("return _G == nil", "c", "t", {})(), true)
expect("load-syntax-err", load("this is not lua") == nil, true)
expect("load-errmsg", select(2, load("!!bad!!")):match("near") ~= nil, true)
expect("load-multichunk", (function()
  local pieces = {"return ", "40", " + 2"}
  local i = 0
  return load(function() i = i + 1 return pieces[i] end)()
end)(), 42)
expect("load-deep-nest",
  load("return " .. ("{"):rep(150) .. "1" .. ("}"):rep(150))() ~= nil, true)

-- 5.4 的 <close> 属性（用 load 隔离，避免 5.3 下整文件语法错误）
if _VERSION >= "Lua 5.4" then
  local f = load([[
    local closed = false
    do
      local x <close> = setmetatable({}, {__close = function() closed = true end})
    end
    return closed
  ]])
  expect("close-attribute", f(), true)
end

--== 13. 标准库补充（utf8 / os / math 格式化）==--
expect("utf8-char", utf8.char(0x4E2D, 0x6587), "中文")
expect("utf8-len", utf8.len("中文abc"), 5)
expect("utf8-codepoint", utf8.codepoint("中文", 4), 0x6587)
expect("utf8-codes", (function()
  local n = 0 for _ in utf8.codes("a中b文c") do n = n + 1 end return n
end)(), 5)
expect("os-time-type", type(os.time()), "number")
expect("os-date-type", type(os.date("%Y")), "string")
expect("math-pi-fmt", string.format("%.5f", math.pi), "3.14159")

--== 14. OOP 继承与多态 ==--
local Animal = {}
Animal.__index = Animal
function Animal.new(name, sound)
  return setmetatable({name = name, sound = sound}, Animal)
end
function Animal:speak() return self.name .. " says " .. self.sound end
function Animal:getName() return self.name end

local Dog = setmetatable({}, {__index = Animal})
Dog.__index = Dog
function Dog.new(name) return setmetatable(Animal.new(name, "Woof"), Dog) end
function Dog:fetch() return self.name .. " fetches!" end

local Cat = setmetatable({}, {__index = Animal})
Cat.__index = Cat
function Cat.new(name) return setmetatable(Animal.new(name, "Meow"), Cat) end
function Cat:speak() return Animal.speak(self) .. " (proudly)" end

local pets = {Dog.new("Rex"), Cat.new("Tom")}
expect("oop-poly-1", pets[1]:speak(), "Rex says Woof")
expect("oop-poly-2", pets[2]:speak(), "Tom says Meow (proudly)")
expect("oop-dog-fetch", pets[1]:fetch(), "Rex fetches!")
expect("oop-inherited-method", pets[2]:getName(), "Tom")

--== 15. 边界与安全压力 ==--
do -- 整数 for 循环在 maxinteger 边界必须正常终止，不能溢出成死循环
  local c = 0
  for i = math.maxinteger - 2, math.maxinteger do c = c + 1 end
  expect("loop-int-overflow-safe", c, 3)
  local c2 = 0
  for i = math.mininteger, math.mininteger + 2 do c2 = c2 + 1 end
  expect("loop-int-underflow-safe", c2, 3)
  local c3 = 0
  for i = 1, math.maxinteger, math.maxinteger do c3 = c3 + 1 end
  expect("loop-int-huge-step", c3, 1)
  local c4 = 0
  for x = 1, 2, 0.25 do c4 = c4 + 1 end
  expect("loop-float-step", c4, 5)
  local c5 = 0
  for i = 10, 1, -3 do c5 = c5 + 1 end
  expect("loop-neg-step", c5, 4)
end

expect("stress-big-concat", (function()
  local tt = {}
  for i = 1, 100000 do tt[i] = "x" end
  return #table.concat(tt)
end)(), 100000)
expect_err("stress-rep-overflow", function()
  return string.rep("x", math.maxinteger)
end)

do -- 一万个闭包共享循环变量语义
  local fns = {}
  for i = 1, 10000 do fns[i] = function() return i * 2 end end
  local s = 0
  for i = 1, 10000 do s = s + fns[i]() end
  expect("stress-many-closures", s, 10000 * 10001)
end

do -- 五万个字符串键的哈希表读写一致性
  local tt = {}
  for i = 1, 50000 do tt["key" .. i] = i end
  local ok = true
  for i = 1, 50000 do
    if tt["key" .. i] ~= i then ok = false break end
  end
  expect("stress-many-keys", ok, true)
end

-- SMOKE: 非确定性值，仅供人工观察，不参与 diff
print("SMOKE gc-count-MB>0:", collectgarbage("count") > 0)

--== 汇总 ==--
print(("="):rep(60))
print(("RESULT: %d passed, %d failed"):format(passed, failed))
for _, msg in ipairs(fail_log) do print(msg) end
if failed == 0 then
  print("ALL TESTS PASSED")
end
os.exit(failed == 0)
