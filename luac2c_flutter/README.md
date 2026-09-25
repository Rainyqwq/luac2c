# luac2c_client

luac2c 的 Windows 桌面客户端。把 `.lua` 文件拖进窗口，一键跑完
"编译字节码 → 转译为 C → gcc 编译 → 运行 → 与 lua.exe 比对"，也可以只生成 C 源码。

入口是 `lib/main.dart`，两个页面在 `lib/home_page.dart`（防护）与 `lib/mine_page.dart`（我的）。
构建方式见仓库根目录 README 的「构建客户端」一节。
