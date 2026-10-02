// 顶部状态条：标题栏下方的一张卡片，与下面的 AppCard 同一套视觉语言。
//
// 形状：圆角卡片，左右留 16px 边距（和下面内容区的 padding 对齐），
// 圆角与 AppCard 同为 16。之前做成横贯整宽的直角色块，那是"工具条"的
// 形态，和下面一列圆角卡片摆在一起像是两个不同的界面。
//
// 配色：按 M3 规范，底色用容器色层（idle / working 走 surface 容器，
// good / bad 走 primary / error 容器），图标与文字用对应的 on* 角色。
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
    final (bg, fg, icon) = switch (ctl.statusLevel) {
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
      // 进行中与空闲都走 surface 容器色，只是图标不同 —— "正在动"由右侧
      // 的 spinner 表达，不必再换一次底色。
      Level.working => (
          cs.surfaceContainerHigh,
          cs.onSurfaceVariant,
          Icons.play_circle_outline
        ),
      Level.idle => (
          cs.surfaceContainerLow,
          cs.onSurfaceVariant,
          Icons.info_outline
        ),
    };

    return Padding(
      // 边距与下面内容区（home_page 里的 16）一致，卡片才像是同一版式里的
      // 一块，而不是贴在标题栏下沿的工具条。
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: bg,
          // 与 widgets.dart 的 AppCard 同一个值
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ctl.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: fg),
            ),
          ),
          // 批量运行时的计数比进度条更直接
          if (ctl.totalCount > 0) ...[
            const SizedBox(width: 16),
            Text('${ctl.doneCount}/${ctl.totalCount}',
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    color: cs.onSurfaceVariant)),
          ],
          if (ctl.busy) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
            ),
          ],
        ]),
      ),
    );
  }
}
