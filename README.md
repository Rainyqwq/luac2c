# luac2c — Lua 5.5 字节码 → Lua C API 的 C 源码翻译器

把 `luac` 编译出的 Lua 5.5 字节码（`.luac`）翻译成等价的、直接调用 Lua C API 的 C 源码，
再用任意 C 编译器与 `liblua.a` 链接成独立可执行文件，输出与 `lua.exe` 逐字节一致。

```
luac.exe -o out.luac in.lua      # 1. Lua 源码编译为字节码
luac2c.exe out.luac -o out.c     # 2. 字节码翻译为 C 源码
gcc out.c -I lua-5.5.1/src -I lua5.5-include -std=c99 -w -O0 -o out.exe lua-5.5.1/build/liblua.a -lm
out.exe                          # 3. 运行，输出与 lua.exe 完全一致
```

## 目录结构

```
├── luac2c.c              # 翻译器源码（单文件实现）
├── lua-5.5.1/            # vendored Lua 5.5（src + build/liblua.a）
├── lua5.5-include/       # 对外暴露的头文件
├── test/                 # 21 个端到端用例 + 测试脚本（test.ps1 / runall.ps1 / sweep.ps1 / sweepall.ps1）
├── luac2c_flutter/       # Windows GUI 客户端（Flutter, Material You / M3）
│   └── lib/              # main / app / app_shell 三个入口，其余按职责分模块
│       ├── pipeline.dart # 构建调度（并发池、进度、状态文案），不含 Widget
│       ├── steps.dart    # 单文件五步：luac → luac2c → gcc → 运行 → 比对
│       ├── tools.dart    # 工具链探测
│       ├── home/ mine/   # 两个页面的部件
│       └── widgets.dart  # 通用卡片/开关/指示灯原语
├── luac2c_client.exe     # 客户端构建产物（build 后拷到根目录）
├── luac.exe / lua.exe    # Lua 5.5 工具链（可由 lua-5.5.1 重建）
└── luac2c_gui.c          # 旧版 Win32 GUI（已淘汰，仅作参考实现保留）
```

## 特性

翻译本身覆盖 Lua 5.5 全部 85 个 opcode，寄存器帧模型、多重返回值、VARARG 开窗、
to-be-closed 语义、generic for 三槽位这些容易出错的运行时细节都处理过。
默认开启多样化编译：每次用时间种子给出不同的寄存器置换、常量池布局与标识符命名，
`--seed N` 可复现，`--static` 是恒等布局的可读基线。

防护分静态加固和运行时守卫两层。两者都在多样化模式下默认开启，被 `--static` 一并关掉。

**静态加固**

- API 间接化：42 个 Lua C API 经运行时解码的函数指针表调用，文件里没有明文导入
- 常量池强化：双密钥混合的常量池解码
- 控制流扁平化：状态机分发器改写全部控制流
- 函数切分：函数体切成由指针表调用的块函数
- 整数 MBA 混淆（`--no-mba` 关闭）：寄存器索引 `b + idx + 1` 与状态机解码 `st - base`
  改用混合布尔算术恒等式书写 —— `x+y == (x^y)+2*(x&y)`、`x+y == (x|y)+(x&y)`、
  `x+y == x-~y-1`，每个函数随机取一种。调用点里 `idx` 是常量，编译器会折叠回同一次加法，
  运行期零开销，但反编译器读不回"基址加下标"
- 常量按需解密 + 用完擦除（`--no-wipe` 退回旧的"启动即全量展开"）：字符串不再在启动时
  被解码成一张 Lua 表，而是每次用到时才从 blob 解到栈上暂存区，入栈后立刻清零
  （`volatile` 写入，防止被优化掉）。任何时刻 dump 内存只能看到当前正在用的那一个常量，
  而不是整个文件的字符串
- 等价替换扩张：`lua_pop(L,1)` 会随机写成等价的 `lua_settop(L, lua_gettop(L)-1)`，
  打散"弹临时值"的固定形态；垃圾指令密度约 45%，并在三分之一的插入点追加第二组不同形态
- 不透明谓词 + 垃圾指令（`--no-opaque` 关闭）：谓词取自 `lua_State` 地址的恒真/恒假恒等式
  （编译器与 IDA 都无法折叠），恒假分支里放永不执行的 Lua 调用、指向真实标签的虚假跳转
  （污染 IDA 重建的 CFG），以及被 `jmp` 跳过的伪 `call` 字节序列（破坏线性扫描反汇编）。
  垃圾指令汇入 `l2c_noise` 依赖链，删掉会被观测到

**运行时守卫与签名校验**（`--no-guard` 关闭）

- 代码区校验：启动时把受保护区切成若干个 1 KiB 窗口各存一份摘要，之后每进入一次生成函数
  就复算其中一个窗口并轮转 —— 一圈之内覆盖全部字节。旧的定长步进取样只查 `0, 97, 194…`，
  落在别的偏移上的补丁永远查不到（改一个字节能活下来的概率约 99%）；现在没有这个盲区，
  而单次开销反而更低（一个窗口，而非扫过整段）
- **守卫代码自保护**：`l2c_scan_env` / `l2c_guard_poll` / `l2c_codesig` 这些检查函数
  以前排在受保护区**之前**，改掉 `l2c_guard_poll` 让它恒返回"干净"，代码签名毫无反应 ——
  整个机制可以被一句话废掉。现在它们被 `l2c_grd_a` / `l2c_grd_b` 框住并单独取摘要，
  改动检查者本身即被检出（所有会被写入的状态变量都挪到了这个区间之外，否则运行期
  改写变量会被误判成补丁）
- 常量池签名：blob 的校验和在生成期算好烧进源码，blob 被改即失配
- 后链接签名：启动基准抓不到已经躺在文件里的补丁，因为基准本身就会从被改的字节上量出来。
  期望值必须在链接之后才产生，所以签名做成了独立的后处理步骤：
  ```
  ./prog --l2c-sig                          # 打印 codesig 与受保护区 rva_a / rva_b
  luac2c --sign prog.exe <rva_a> <rva_b>    # 把期望哈希写回二进制的签名槽
  ```
  之后每次启动都把受保护区在文件里的字节与槽中的期望值比对（对文件而非内存计算，
  不受重定位影响），并同时校验文件大小，实测改 1 个字节即失配。
  没有第二个工具时，也可 `./prog --l2c-sig` 后用 `-DL2C_SIG=0x<code>` 重编替代
- `--require-sig`：未签名的映像直接视为被篡改，防止直接删掉签名槽
- 环境取证：调试器（`IsDebuggerPresent` / `TracerPid` / `P_TRACED`）、直读 PEB 的
  `BeingDebugged` 与 `NtGlobalFlag`（`IsDebuggerPresent` 是反反调试插件最先挂钩的 API，
  读 PEB 原始字段可以绕过被改的 API）、frida|gadget|gum|jshook|dobby|minhook|detours|injector
  模块与内存映射、Frida 的 `gmain`/`gum-js-loop` 线程、`LD_PRELOAD`、
  `ptrace(PTRACE_TRACEME)`、API 入口首字节 inline hook（`E9`/`EB`/`CC`）、受保护区所在代码页
  的可写属性，以及时间差检测（单步跟踪下一个平凡循环会慢几个数量级，阈值取 0.5 秒，
  远高于正常抖动，宁可放过也不误伤正常机器）
- 反制方式：命中任意一项即置位标志（位：`1` 调试器 `2` 被跟踪 `4` frida 模块 `8` frida 线程
  `16` 预加载 `32` API 被挂钩 `64` 常量池失配 `128` PEB 调试标志 `256` PEB 全局标志
  `512` 时间差），同时污染常量池密钥与栈帧基址。程序照常跑完并正常退出，读写的寄存器却全部
  错位；这里没有可以 nop 掉的分支，因为校验代码本身就位于它所度量的区域之内
- `L2C_GUARD_REPORT=1` 打印测量结果（code / guard / windows / flags / noise）

验证方式（两条都实测过）：`-DL2C_SELFTEST` 编译会让程序在取完基线后翻转受保护区内的一个
字节，正常构建不含这段代码；结果程序给出失配响应，输出与 `lua.exe` 不再一致。
文件侧则用 `--l2c-sig` + `--sign` 固化后改一个字节，同样被检出。
输入侧另有 400 轮模糊测试（355 个畸形输入被拒收，0 崩溃）。

**GUI 客户端**（`luac2c_flutter/`，Material You / Material Design 3）

一键构建并比对依次做"编译字节码 → 转译为 C → gcc 编译 → 运行 → 与 lua.exe 比对"，多文件并发；另有「仅生成 C 源码」只跑前两步。批量模式下多选或拖入多个 `.lua` 文件依次
处理，每个文件单独标记通过或失败，配进度条与「停止」按钮。

工具链自动探测，源码里不含任何本机路径：环境变量 → `luac2c_gui.ini` → 工程根目录 →
程序所在目录 → 系统 `PATH` → 常见 MinGW/MSYS2 位置，详见下方「工具链解析」。指示灯用
「字节码编译器 / 转译器 / 脚本引擎 / C 编译器」标注，悬停看具体路径。

代码布局三选一：随机（默认，每次不同）、固定种子（可复现）、不混淆（`--static`，原样直译）。
开关项有运行时防护（默认开，关 = `--no-guard`）、关闭常量池（`--no-pool`）、
保留指令注释（`--annotate`）。另外有实时运行日志、一键重新编译 luac2c.exe、
种子色调色盘与明暗主题（均持久化）、分级超时与取消。

## 工具链解析

项目里没有写死任何本机路径。客户端与脚本按下表顺序定位工具链，任一步命中即止：

1. 环境变量（优先级最高）

   | 变量 | 用途 |
   | --- | --- |
   | `LUAC2C_ROOT` | 工程根目录（含 `luac2c.c` 与 `lua-5.5.1/src`） |
   | `LUAC` / `LUAC2C` / `LUA` | 三个可执行文件的完整路径 |
   | `GCC`（亦可写 `CC`） | C 编译器；给不出来才继续往下找 |
   | `MINGW_HOME` / `MINGW64_HOME` / `MSYSTEM_PREFIX` / `MSYS2_ROOT` | MinGW 安装根目录 |

2. 程序所在目录的 `luac2c_gui.ini`，`[paths]` 段：
   `root` / `luac` / `luac2c` / `lua` / `gcc` / `inc1` / `inc2` / `lib`
3. 工程根目录：由程序所在目录与当前工作目录逐级向上探测（找 `luac2c.c` + `lua-5.5.1/src`）
4. 程序所在目录
5. 系统 `PATH`
6. 常见安装位置（`%SystemDrive%\mingw64\bin`、`%SystemDrive%\msys64\mingw64\bin`、
   TDM-GCC-64、Strawberry …）；仍找不到时，才在系统盘 / `Program Files` 下做有预算的
   两层浅扫找 `gcc.exe`（总量封顶、命中即返回，不会遍历整个磁盘）

`test\*.ps1` 与 `.workbuddy/tm/runall.sh` 同样不写死路径：根目录由脚本自身位置推导
（可用 `LUAC2C_ROOT` 覆盖），gcc 取 `$env:GCC` / `$GCC`，其次 `PATH`。

## 构建客户端

```powershell
cd luac2c_flutter
flutter pub get
flutter build windows --release
# 产物在 build\windows\x64\runner\Release\，拷到项目根即可使用
```

## 测试

```powershell
cd test
powershell -NoProfile -ExecutionPolicy Bypass -File runall.ps1     # 全量 21 用例
powershell -NoProfile -ExecutionPolicy Bypass -File sweepall.ps1 -MaxSeed 4   # 跨种子扫描
```

## 许可

本项目依赖的 Lua 5.5 遵循 MIT License（见 `lua-5.5.1/`）。
