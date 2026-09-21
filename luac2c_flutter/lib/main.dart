// luac2c 客户端入口（Flutter Windows Desktop, Material You / M3）
//
// 与 Win32 原生版 luac2c_gui.c 功能一致：
//   完整流程: 编译字节码 -> 转译为 C -> gcc 编译 -> 运行 -> 与 lua.exe 输出比对
//   仅生成 C 源码 / 重新编译 luac2c.exe / 三种代码布局 + 常量池、注释等输出选项
//   拖拽 .lua 文件（runner 原生 WM_DROPFILES）、日志窗格
//
// 模块划分：
//   app.dart        应用根（主题 -> MaterialApp）
//   app_shell.dart  标题栏 + 底部导航
//   home_page.dart  主界面（纯 UI）
//   pipeline.dart   构建流水线控制层（无 Widget）
//   tools.dart      工具链探测（只认环境变量/ini/自动探测，不写死本机路径）
//   runner.dart     子进程执行（超时/取消/截断/GBK 容错）
//   widgets.dart / log_pane.dart  通用组件与日志面板
//   theme.dart      明暗 + 种子色持久化与 M3 主题
//   account.dart / mine_page.dart / sha256.dart  本地账号与用户指纹
import 'package:flutter/material.dart';

import 'account.dart';
import 'app.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeCtl.I.load();
  await AccountCtl.I.load(); // 恢复"记住我"的会话
  runApp(const Luac2cApp());
}
