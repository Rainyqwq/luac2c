// 顶部状态条：固定在标题栏正下方，横跨整个窗口宽度。
//
// 位置：放在标题栏下方（原先在底边，贴着日志区显得像日志的一部分）。
//
// 配色按 M3 规范：底色一律用 surface 层的容器色（level 越高越靠 surface），
// 语义色只落在图标和文字上（primary / error / onSurfaceVariant）。
// M3 不靠"整条铺一个彩色底"表达状态 —— 那是传统桌面的做法，在 M3 里
// 属于色彩角色误用：primaryContainer 之类的容器色是给"容器"用的，
// 不是给细长信息条用的。
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
      // 进行中与空闲都用同一档容器色，只是图标不同。
      // 状态"正在动"由右侧的 spinner 表达，不必再换底色。
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

    return Container(
      height: 40,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(children: [
        Icon(icon, size: 16, color: fg),
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
            child:
                CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
        ],
      ]),
    );
  }
}
