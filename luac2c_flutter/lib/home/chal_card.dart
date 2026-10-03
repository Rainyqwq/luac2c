// 挑战应答卡片：让产物能对服务端 nonce 给出应答。
//
// 与其他开关的区别：这个功能**在构建时改变产物本身**（luac2c 往里写一个
// 应答函数），所以它必须跟着构建走，"构建完再点"没有意义。卡片上的按钮
// 做的不是开启它，而是**从刚构建出来的产物上取一次应答**，用来验证链路
// 通不通、以及交给服务端比对。
//
// 主程序不认识 --chal 时整张卡片降级为一句说明，不给用户一个点了会失败的
// 开关 —— 客户端可以配到任意一份 luac2c.exe，包括早于这个功能的版本。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pipeline.dart';
import '../steps.dart';
import '../widgets.dart';

class ChalCard extends StatelessWidget {
  final PipelineCtl ctl;
  const ChalCard(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final supported = ctl.tools.l2cChal;
    final plain = ctl.mode == layoutPlain;

    if (!supported) {
      return AppCard(
        title: '挑战应答',
        icon: Icons.key_outlined,
        children: [
          Text('当前主程序不支持这项功能，换一份新版的 luac2c.exe 后可用。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
      );
    }

    final answer = ctl.chalAnswer;
    return AppCard(
      title: '挑战应答',
      icon: Icons.key_outlined,
      children: [
        SwitchRow(
          icon: Icons.verified_user_outlined,
          title: '构建时写入应答能力',
          subtitle: plain
              ? '「不混淆」模式下不会写入：那一档关掉的正是这些防护'
              : '产物会带一个应答函数，能对服务端给的 nonce 作出应答',
          value: ctl.chal && !plain,
          enabled: !ctl.busy && !plain,
          onChanged: ctl.setChal,
        ),
        if (ctl.chal && !plain) ...[
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(
              width: 96,
              child: Text('池条目槽位',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: ctl.chalSlot,
                  enabled: !ctl.busy,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '0',
                  ),
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: '从刚构建的产物上取一次应答 (Ctrl+R)',
              child: OutlinedButton.icon(
                onPressed: ctl.busy ? null : ctl.fetchChalAnswer,
                icon: const Icon(Icons.query_stats, size: 16),
                label: const Text('取应答'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            answer == null
                ? '应答：尚未取过。构建完成后点「取应答」，再把结果交给服务端比对。'
                : '应答：$answer',
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'Consolas',
              color: answer == null ? cs.onSurfaceVariant : cs.primary,
            ),
          ),
          if (answer != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: answer));
                  ctl.noteChalCopied();
                },
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text('复制应答'),
              ),
            ),
          ],
        ],
      ],
    );
  }
}
