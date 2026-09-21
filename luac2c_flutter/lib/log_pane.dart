// 运行日志面板。
//
// 自己持有滚动控制器与"是否跟随底部"状态，只订阅 [LogStore]，
// 因此日志刷新不会重建主页的其它部分。
import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scroll.hasClients) {
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    }
                  });
                }
                return Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    child: RepaintBoundary(
                      child: SelectableText(
                        widget.log.lines.isEmpty
                            ? '（暂无输出）'
                            : widget.log.lines.join('\n'),
                        style: TextStyle(
                            fontFamily: 'Consolas',
                            fontFamilyFallback: const ['Microsoft YaHei UI'],
                            fontSize: 12,
                            height: 1.45,
                            color: cs.onSurface),
                      ),
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
