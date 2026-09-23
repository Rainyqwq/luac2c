// 代码防护卡片：布局三选一 + 种子 + 三个输出开关。
import 'package:flutter/material.dart';

import '../pipeline.dart';
import '../steps.dart';
import '../widgets.dart';

class ModeCard extends StatelessWidget {
  final PipelineCtl ctl;
  const ModeCard(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      title: '代码防护',
      icon: Icons.tune,
      children: [
        Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(
                    value: layoutRandom,
                    label: Text('随机'),
                    icon: Icon(Icons.shuffle)),
                ButtonSegment<int>(
                    value: layoutSeed,
                    label: Text('固定种子'),
                    icon: Icon(Icons.tag)),
                ButtonSegment<int>(
                    value: layoutPlain,
                    label: Text('不混淆'),
                    icon: Icon(Icons.lock_open_outlined)),
              ],
              selected: {ctl.mode},
              onSelectionChanged: (s) {
                if (!ctl.busy) ctl.setMode(s.first);
              },
            ),
          ),
          const SizedBox(width: 10),
          Opacity(
            opacity: ctl.mode == layoutSeed ? 1 : 0.45,
            child: SizedBox(
              width: 78,
              height: 40,
              child: TextField(
                controller: ctl.seed,
                enabled: !ctl.busy && ctl.mode == layoutSeed,
                decoration: const InputDecoration(
                  labelText: '种子',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text(ctl.modeHint,
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        const Divider(height: 22),
        SwitchRow(
          icon: Icons.security_outlined,
          title: '运行时防护',
          subtitle: ctl.mode == layoutPlain
              ? '「不混淆」模式下 luac2c 不会启动防护'
              : '注入反调试与完整性自校验，局部修改会产生静默错误',
          value: ctl.guard && ctl.mode != layoutPlain,
          enabled: !ctl.busy && ctl.mode != layoutPlain,
          onChanged: ctl.setGuard,
        ),
        const SizedBox(height: 4),
        SwitchRow(
          icon: Icons.inventory_2_outlined,
          title: '关闭常量池',
          subtitle: '常量和字符将直接写进 C 源码',
          value: ctl.noPool,
          enabled: !ctl.busy,
          onChanged: ctl.setNoPool,
        ),
        const SizedBox(height: 4),
        SwitchRow(
          icon: Icons.comment_outlined,
          title: '保留指令注释',
          subtitle: '在生成的 C 源码里逐条标注字节码指令',
          value: ctl.annotate,
          enabled: !ctl.busy,
          onChanged: ctl.setAnnotate,
        ),
      ],
    );
  }
}
