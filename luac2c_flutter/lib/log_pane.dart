// 运行日志面板。
//
// 自己持有滚动控制器与"是否跟随底部"状态，只订阅 [LogStore]，
// 因此日志刷新不会重建主页的其它部分。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'widgets.dart';

class LogPane extends StatefulWidget {
  final LogStore log;
  final VoidCallback? onCopied;
  const LogPane({super.key, required this.log, this.onCopied});

  @override
  State<LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<LogPane> {
  final ScrollController _scroll = ScrollController();
  // 日志是否自动跟随底部（用户往上翻看历史时暂停跟随）
  bool _stickBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _stickBottom = _scroll.position.extentAfter < 24;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.log.lines.join('\n')));
    widget.onCopied?.call();
  }

  /// 滚到底部。变高 item 的滚动范围是估算值，一次性追加一大批行之后
  /// 再校正一帧，否则会停在"上次"的底部。
  void _toBottom() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent <= 0) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Microsoft YaHei UI'],
      fontSize: 12,
      height: 1.45,
      color: cs.onSurface,
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 4),
            child: Row(children: [
              Icon(Icons.terminal, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('运行日志',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const Spacer(),
              // 行数用 ListenableBuilder 单独订阅，避免整页随日志重建
              ListenableBuilder(
                listenable: widget.log,
                builder: (context, _) => Text('${widget.log.lines.length} 行',
                    style: TextStyle(
                        fontSize: 11.5, color: cs.onSurfaceVariant)),
              ),
              TextButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text('复制'),
              ),
              TextButton.icon(
                onPressed: widget.log.clear,
                icon: const Icon(Icons.delete_outline, size: 15),
                label: const Text('清空'),
              ),
            ]),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.log,
              builder: (context, _) {
                // 新日志到达后跟随到底部（用户上翻时由 _stickBottom 暂停）
                if (_stickBottom) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
                }
                final lines = widget.log.lines;
                if (lines.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('（暂无输出）', style: style),
                  );
                }
                // 逐行虚拟化：只布局视口内的行。原来是一整个 SelectableText，
                // 每刷新一次都要把上千行重新排版一遍，批量处理时会明显发顿。
                return Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: lines.length,
                      // 多缓存一些，跟随底部时向上翻动不会现白
                      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                      itemBuilder: (context, i) => Text(lines[i], style: style),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
