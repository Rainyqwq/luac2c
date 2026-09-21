// 通用小组件与日志存储器。
//
// 这些组件不依赖任何业务状态，主页与其它界面都直接复用。
import 'dart:async';

import 'package:flutter/material.dart';

/// 卡片内小标题
class SectionTitle extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
      ],
      Text(text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: cs.primary,
              letterSpacing: 0.2)),
      const Spacer(),
      ?trailing,
    ]);
  }
}

/// 工具状态指示灯（M3：error / primary 容器配色）
class StatusDot extends StatelessWidget {
  final bool ok;
  final String label;
  final String path;
  const StatusDot(
      {super.key, required this.ok, required this.label, required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: path,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: ok ? cs.primaryContainer : cs.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok ? Icons.check_circle : Icons.error,
              size: 13, color: ok ? cs.onPrimaryContainer : cs.onErrorContainer),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: ok ? cs.onPrimaryContainer : cs.onErrorContainer)),
        ]),
      ),
    );
  }
}

/// 日志存储器：独立可监听容器 + 节流批量刷新。
/// 配合 ListenableBuilder 使用，日志刷新只重建日志面板本身，
/// 不会连带重建文件列表/工具链卡片/按钮区（批量跑几十个文件时体感差别很大）。
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
