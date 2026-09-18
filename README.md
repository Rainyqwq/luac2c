# luac2c — Lua 5.5 字节码 → Lua C API 的 C 源码翻译器

把 `luac` 编译出的 Lua 5.5 字节码（`.luac`）翻译成等价的、直接调用 **Lua C API** 的 C 源码，
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
├── test/                 # 20 个端到端用例 + 测试脚本（test.ps1 / runall.ps1 / sweep.ps1 / sweepall.ps1）
├── luac2c_flutter/       # Windows GUI 客户端（Flutter, Material You / M3）
│   └── lib/main.dart
├── luac2c_client.exe     # 客户端构建产物（build 后拷到根目录）
├── luac.exe / lua.exe    # Lua 5.5 工具链（可由 lua-5.5.1 重建）
└── luac2c_gui.c          # 旧版 Win32 GUI（已淘汰，仅作参考实现保留）
```

## 特性

- **完整翻译**：覆盖 Lua 5.5 全部 85 个 opcode；寄存器帧模型、多重返回值、
  VARARG 开窗、to-be-closed 语义、generic for 三槽位等运行时细节均已处理
- **多样化编译**（默认开启）：随机时间种子，每次生成不同的寄存器置换、常量池布局与标识符命名，
  `--seed N` 可复现，`--static` 为恒等布局基线
- **静态对抗加固**（多样化模式默认开启，`--static` 强制关闭）：
  - API 间接化：42 个 Lua C API 经运行时解码的函数指针表调用，无明文导入
  - 常量池强化：双密钥混合的常量池解码
  - 控制流扁平化：状态机分发器改写全部控制流
  - 函数切分：函数体切分为指针表调用的块函数
  - **不透明谓词 + 垃圾指令**（`--no-opaque` 关闭）：谓词取自 `lua_State` 地址的
    恒真/恒假恒等式（编译器与 IDA 都无法折叠），恒假分支里放永不执行的 Lua 调用、
    指向真实标签的虚假跳转（污染 IDA 重建的 CFG），以及被 `jmp` 跳过的伪 `call`
    字节序列（破坏线性扫描反汇编）。垃圾指令汇入 `l2c_noise` 依赖链，删掉即被观测
- **运行时守卫与签名校验**（默认开启，`--no-guard` 关闭）：
  - **代码区签名**：对 `[l2c_sig_a, l2c_sig_b)` 这段机器码做 FNV 校验，启动时采样
    为基准，之后每次进入生成的函数都复查 —— Frida / 调试器在运行途中安装的
    inline hook、`int3` 断点都会改变它
  - **常量池签名**：blob 的校验和在生成期算好烧进源码，blob 被改即失配
  - **后链接签名（推荐，堵住"改文件后重启"）**：启动基准只能抓运行途中下的钩子，
    抓不到**已经躺在文件里的补丁**（基准本身就会从被改的字节上量出来）。要堵这个洞，
    期望值必须在链接之后才产生，所以签名是一个独立的后处理步骤：
    ```
    ./prog --l2c-sig                          # 打印 codesig 与受保护区 rva_a / rva_b
    luac2c --sign prog.exe <rva_a> <rva_b>    # 把期望哈希写回二进制的签名槽
    ```
    之后每次启动都会把受保护区在**文件里**的字节与槽中的期望值比对（对文件而非内存
    计算，因此不受重定位影响），并同时校验文件大小。实测改 1 个字节即失配。
    没有第二个工具时，也可 `./prog --l2c-sig` 后用 `-DL2C_SIG=0x<code>` 重编替代
  - **`--require-sig`**：未签名的映像直接视为被篡改（防止直接删掉签名槽）
  - **环境取证**：调试器（`IsDebuggerPresent` / `TracerPid` / `P_TRACED`）、
    frida|gadget|gum|jshook 模块与内存映射、Frida 的 `gmain`/`gum-js-loop` 线程、
    `LD_PRELOAD`、`ptrace(PTRACE_TRACEME)`、API 入口首字节 inline hook（`E9`/`EB`/`CC`）、
    以及受保护区所在代码页的可写属性（Frida 下钩子前必须先把它改成可写）
  - **反制方式**：命中任意一项即置位标志，同时污染常量池密钥与栈帧基址 —— 程序
    照常跑完并正常退出，但读写的寄存器全部错位。这里**没有可以 nop 掉的分支**，
    因为校验代码本身就位于它所度量的区域之内
  - `L2C_GUARD_REPORT=1` 可打印测量结果
- **GUI 客户端**（`luac2c_flutter/`，Material You / Material Design 3）：
  - **一键构建并比对**：编译字节码 → 转译为 C → gcc 编译 → 运行 → 与 lua.exe 逐字节比对
    （多文件并发工作池），另有「仅生成 C 源码」只跑前两步
  - **批量模式**：多选/拖入多个 `.lua` 文件依次处理，逐文件标记通过/失败
  - 工具自动探测：exe 同目录 → 根目录 → 系统 `PATH` 环境变量，可被 `luac2c_gui.ini` 覆盖；
    指示灯用「字节码编译器 / 转译器 / 脚本引擎 / C 编译器」标注，悬停看具体路径
  - **代码布局三选一**：随机（默认，每次不同）/ 固定种子（可复现）/ 不混淆（`--static`，原样直译）；
    开关项：运行时防护（默认开，关 = `--no-guard`）、关闭常量池（`--no-pool`）、
    保留指令注释（`--annotate`）
  - 实时运行日志，一键重新编译 luac2c.exe，种子色调色盘 + 明暗主题（均持久化），
    进度条与「停止」按钮，分级超时与取消
  - 种子色调色盘 + 明暗主题（均持久化），进度条与「停止」按钮，分级超时与取消

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
