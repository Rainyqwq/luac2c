// 系统文件对话框与资源管理器定位。
//
// 这两件事以前是这么做的：拉起 powershell.exe + WinForms 的 OpenFileDialog，
// 把选中的路径用 Write-Output 打到管道里再读回来。两个硬伤：
//
//   1) powershell 进程没有 PerMonitorV2 感知（manifest 只给 runner 声明了），
//      系统按 96 DPI 渲染那个对话框再位图放大，高分屏上必然发虚 —— 就是
//      "弹出的选择界面分辨率低"的来源；
//   2) 对话框的父窗口是 powershell 的控制台，会被主窗口压住，用户以为
//      没反应；顺带还闪一个黑框，路径还得做编码往返，中文路径会坏。
//
// 现在改成 runner 里直接调 IFileOpenDialog（资源管理器用的就是它），
// 同一个进程、同一个 HWND 当父窗口、宽字符路径直接取，全都没有了。
//
// runner 侧实现见 windows/runner/flutter_window.cpp 的 ShowOpenDialog()。
import 'dart:io';

import 'package:flutter/services.dart';

class WinDialog {
  WinDialog._();
  static final WinDialog I = WinDialog._();

  static const _ch = MethodChannel('luac2c/file');

  /// 挂上原生回调。每次进主界面调一次即可，重复挂是覆盖而非叠加。
  void ensureHandler(void Function(List<String> paths) onPicked) {
    if (!Platform.isWindows) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'picked') return null;
      final a = call.arguments;
      final paths = a is List
          ? a.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
          : <String>[];
      onPicked(paths);
      return null;
    });
  }

  /// 弹出系统多选文件对话框。返回选中的路径；用户取消返回空列表。
  ///
  /// 原生侧是"请求 → 回调"两段式，这里返回的 Future 只表示请求已发出，
  /// 真正的结果走 [ensureHandler] 注册的回调。
  Future<void> pickFiles() async {
    if (!Platform.isWindows) {
      throw StateError('文件对话框仅在 Windows 上可用');
    }
    await _ch.invokeMethod<void>('pick');
  }

  /// 在资源管理器中定位到该文件（带 /select，会高亮选中）。
  void revealInExplorer(String path) {
    if (!Platform.isWindows) return;
    _ch.invokeMethod<void>('reveal', {'path': path});
  }
}
