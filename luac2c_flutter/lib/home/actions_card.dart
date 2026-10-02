// 操作区：一键构建 / 停止 / 进度条 / 三个次操作按钮。
//
// 主按钮上标注快捷键（Ctrl+Enter / Esc），Windows 用户是照着提示找键位的，
// 不太可能去猜。
import 'package:flutter/material.dart';

import '../pipeline.dart';
import '../widgets.dart';

class ActionsSection extends StatelessWidget {
  final PipelineCtl ctl;
  const ActionsSection(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(children: [
        Expanded(
          child: Tooltip(
            message: '编译字节码 → 转译为 C → gcc 编译 → 运行生成物 (Ctrl+Enter)',
            child: FilledButton.icon(
              onPressed: ctl.busy ? null : () => ctl.run(full: true),
              icon: ctl.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 20),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('一键构建', style: TextStyle(fontSize: 15)),
              ),
            ),
          ),
        ),
        if (ctl.busy) ...[
          const SizedBox(width: 10),
          Tooltip(
            message: '终止正在运行的子进程 (Esc)',
            child: FilledButton.tonalIcon(
              onPressed: ctl.stop,
              icon: const Icon(Icons.stop, size: 18),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('停止', style: TextStyle(fontSize: 14)),
              ),
            ),
          ),
        ],
      ]),
      if (ctl.busy) ...[
        const SizedBox(height: 8),
        // M3 的进度条两端是圆头（track 与 indicator 同粗、圆角为半高）
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value:
                ctl.totalCount == 0 ? null : ctl.doneCount / ctl.totalCount,
            minHeight: 8,
          ),
        ),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: MinorButton(Icons.description_outlined, '仅生成 C 源码',
              ctl.busy ? null : () => ctl.run(full: false),
              tip: '仅生成 C 源码，不运行生成物'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MinorButton(Icons.build_outlined, '重新编译 luac2c',
              ctl.busy ? null : ctl.rebuild,
              tip: '用 gcc 重新编译 luac2c.c，生成新的 luac2c.exe'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MinorButton(Icons.folder_open_outlined, '打开输出目录',
              ctl.busy ? null : ctl.openOutDir,
              tip: '在资源管理器中定位到第一个源文件'),
        ),
      ]),
    ]);
  }
}
