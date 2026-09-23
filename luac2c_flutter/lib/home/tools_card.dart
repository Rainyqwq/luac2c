// 工具链卡片：四个工具的指示灯 + 根目录 + 缺失时的排查提示。
import 'package:flutter/material.dart';

import '../pipeline.dart';
import '../widgets.dart';

class ToolsCard extends StatelessWidget {
  final PipelineCtl ctl;
  const ToolsCard(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ctl.tools;
    return AppCard(
      title: '工具链',
      icon: Icons.build_outlined,
      trailing: t.allOk
          ? const StatusDot(ok: true, label: '就绪', path: '所有工具已找到')
          : const StatusDot(ok: false, label: '有缺失', path: '见下方指示灯'),
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          StatusDot(ok: t.luacOk, label: '字节码编译器', path: t.luac),
          StatusDot(ok: t.l2cOk, label: '主程序', path: t.l2c),
          StatusDot(ok: t.luaOk, label: 'lua', path: t.lua),
          StatusDot(ok: t.gccOk, label: 'C 编译器', path: t.gcc),
        ]),
        const SizedBox(height: 10),
        Text('根目录  ${t.root}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11, color: cs.onSurfaceVariant, fontFamily: 'Consolas')),
        if (!t.allOk) ...[
          const SizedBox(height: 6),
          Text(
            '自动探测未找齐。可用环境变量 LUAC / LUAC2C / LUA / GCC 指定，'
            '或在程序目录的 luac2c_gui.ini 里配置 [paths] 段。',
            style: TextStyle(fontSize: 11, color: cs.error),
          ),
        ],
      ],
    );
  }
}
