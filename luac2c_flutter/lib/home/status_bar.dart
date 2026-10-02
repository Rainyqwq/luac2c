// 顶部状态条：固定在标题栏正下方，横跨整个窗口宽度。
//
// 位置：从窗口底边挪到了顶部。底边那条太沉，而且贴着日志区，看起来像是
// 日志的一部分；放到标题栏下方更像"这一轮操作的即时反馈"，也接近
// Windows 标题栏下方的信息带。
//
// 配色：底色一律中性，只有图标和文字按等级着色。原先整条铺
// errorContainer / primaryContainer 色块，在 30px 这么窄的一条上又艳又
// 吵 —— 状态等级该体现在文字上，不该靠大色块喊。
//
// 判定来自 [PipelineCtl.statusLevel]，不解析文案 —— 改一句提示词不至于
// 让配色悄悄失配。
import 'package:flutter/material.dart';

import '../pipeline.dart';

class StatusBar extends StatelessWidget {
  final PipelineCtl ctl;
  const StatusBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (fg, icon) = switch (ctl.statusLevel) {
      Level.bad => (cs.error, Icons.error_outline),
      Level.good => (cs.primary, Icons.check_circle_outline),
      Level.working => (cs.onSurfaceVariant, Icons.play_circle_outline),
      Level.idle => (cs.onSurfaceVariant, Icons.info_outline),
    };

    return Container(
      height: 30,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        // 在顶部，分隔线走下沿。上方靠 AppBar 的 elevation 区分，不再加线，
        // 否则上下都有线显得碎。
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ctl.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: fg),
          ),
        ),
        // 批量运行时的计数比进度条更直接
        if (ctl.totalCount > 0) ...[
          const SizedBox(width: 12),
          Text('${ctl.doneCount}/${ctl.totalCount}',
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'Consolas',
                  color: cs.onSurfaceVariant)),
        ],
        if (ctl.busy) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: cs.onSurfaceVariant),
          ),
        ],
      ]),
    );
  }
}
