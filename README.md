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
├── luac2c_flutter/       # Windows GUI 客户端（Flutter, Cupertino 风格）
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
- **GUI 客户端**（`luac2c_flutter/`，Cupertino/iOS 风格）：
  - 一键流水线：翻译 → 编译 → 运行 → 与 lua.exe 逐字节比对
  - **批量模式**：多选/拖入多个 `.lua` 文件依次处理，逐文件标记通过/失败
  - 工具自动探测：exe 同目录 → 根目录 → 系统 `PATH` 环境变量，可被 `luac2c_gui.ini` 覆盖
  - 三种翻译模式 + `--no-pool` / `--annotate`，实时日志，一键重建 luac2c

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
