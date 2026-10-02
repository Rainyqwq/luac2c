// 底部状态栏：固定在窗口底边，整条宽度，承载进度与提示。
//
// 三处设计都是针对上一版的问题：
//
//  1) 固定。它原先排在左栏滚动区的最后一项，不滚到底就看不见 —— 而进度和
//     提示恰恰是全程最需要盯的东西。Windows 的状态栏本来就在窗口底边、
//     永不随内容滚动，这里照做。
//  2) 整条。原先只占左栏那一列，右边的日志区看不到状态。现在横跨全宽。
//  3) 不再弹浮层。原先提示走 SnackBar，它从底部浮起来正好压住状态条，
//     等于把结果盖住了。现在提示直接写进这条里，没有会挡视野的东西。
//
// 配色与图标来自 [PipelineCtl.statusLevel]，不靠解析文案 —— 改一句提示词
// 不会让配色悄悄失配。
import 'package:flutter/material.dart';

import '../pipeline.dart';

class StatusBar extends StatelessWidget {
  final PipelineCtl ctl;
  const StatusBar(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lvl = ctl.statusLevel;
    final (bg, fg, icon) = switch (lvl) {
      Level.bad => (
          cs.errorContainer,
          cs.onErrorContainer,
          Icons.error_outline
        ),
      Level.good => (
          cs.primaryContainer,
          cs.onPrimaryContainer,
          Icons.check_circle_outline
        ),
      Level.working => (
          cs.surfaceContainerHighest,
          cs.onSurfaceVariant,
          Icons.play_circle_outline
        ),
      Level.idle => (
          cs.surfaceContainerHighest,
          cs.onSurfaceVariant,
          Icons.info_outline
        ),
    };

    return Container(
      height: 32,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(children: [
        Icon(icon, size: 15, color: fg),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ctl.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: fg),
          ),
        ),
        if (ctl.busy) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: fg),
          ),
        ],
        // 批量运行时有计数，比进度条更直接
        if (ctl.totalCount > 0) ...[
          const SizedBox(width: 14),
          Text('${ctl.doneCount}/${ctl.totalCount}',
              style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'Consolas',
                  color: fg)),
        ],
      ]),
    );
  }
}
