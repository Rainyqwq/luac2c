// 顶部窄条：一眼看出产物到底带不带账号指纹。
import 'package:flutter/material.dart';

import '../account.dart';

class LoginStrip extends StatelessWidget {
  const LoginStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AccountCtl.I,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final on = AccountCtl.I.loggedIn;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: on ? cs.primaryContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            Icon(on ? Icons.fingerprint : Icons.person_off_outlined,
                size: 16,
                color: on ? cs.onPrimaryContainer : cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                on
                    ? '已登录 ${AccountCtl.I.name} · ID ${AccountCtl.I.fingerprint}'
                    : '未登录',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: on ? cs.onPrimaryContainer : cs.onSurfaceVariant),
              ),
            ),
          ]),
        );
      },
    );
  }
}
