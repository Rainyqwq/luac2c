// 底部状态条：按文案判定成功/失败/中性，配色与图标随之变化。
import 'package:flutter/material.dart';

import '../pipeline.dart';

class StatusBar extends StatelessWidget {
  final PipelineCtl ctl;
  const StatusBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = ctl.status;
    // 判定靠这些前缀/关键词：改状态文案时要同步这里
    final ok = s.startsWith('通过') ||
        s.startsWith('批量通过') ||
        s.contains('已重新编译') ||
        s.contains('已复制');
    final bad = s.startsWith('失败') ||
        s.startsWith('不一致') ||
        s.endsWith('失败');
    final bg = bad
        ? cs.errorContainer
        : ok
            ? cs.primaryContainer
            : cs.surfaceContainerHighest;
    final fg = bad
        ? cs.onErrorContainer
        : ok
            ? cs.onPrimaryContainer
            : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(
            bad
                ? Icons.error_outline
                : ok
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
            size: 18,
            color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Text(s,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
        ),
        if (ctl.busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          ),
      ]),
    );
  }
}
