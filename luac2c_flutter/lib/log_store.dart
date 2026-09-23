// 日志存储器：独立可监听容器 + 节流批量刷新。
//
// 单独成文件是为了让 widgets.dart 保持"纯 UI"——日志面板只订阅这里，
// 不会连带重建文件列表、工具链卡片和按钮区（批量跑几十个文件时体感差别很大）。
import 'dart:async';

import 'package:flutter/material.dart';

/// 日志存储器：写操作先进缓冲，[flush] 时一次性合入 [lines] 并只通知一次。
class LogStore extends ChangeNotifier {
  final List<String> lines = <String>[];
  final List<String> _buf = <String>[];
  Timer? _timer;
  static const int maxLines = 4000;

  void add(String s) {
    _buf.add(s);
    if (_buf.length >= 200) {
      flush();
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 80), flush);
  }

  void addAll(Iterable<String> it) {
    _buf.addAll(it);
    if (_buf.length >= 200) {
      flush();
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 80), flush);
  }

  /// 把缓冲里的行一次性合入（节流刷新点）
  void flush() {
    _timer = null;
    if (_buf.isEmpty) return;
    lines.addAll(_buf);
    _buf.clear();
    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
      lines.insert(0, '… （更早的日志已自动销毁，仅保留最近 $maxLines 行）');
    }
    notifyListeners();
  }

  void clear() {
    _buf.clear();
    lines.clear();
    notifyListeners();
  }

  /// 释放定时器（注意：不能叫 dispose，会与 ChangeNotifier.dispose 冲突）
  void close() {
    _timer?.cancel();
    _timer = null;
  }
}
