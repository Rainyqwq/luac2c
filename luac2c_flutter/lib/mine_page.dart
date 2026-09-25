// 「我的」页面：账号资料 + 用户ID + 说明。
//
// 表单在 mine/login_form.dart，账号与指纹的来龙去脉见 account.dart。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account.dart';
import 'mine/login_form.dart';
import 'widgets.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  int _users = 0;

  @override
  void initState() {
    super.initState();
    _refreshCount();
  }

  Future<void> _refreshCount() async {
    final n = await AccountCtl.I.userCount();
    if (mounted) setState(() => _users = n);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AccountCtl.I,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        children: [
          if (AccountCtl.I.loggedIn) ...[
            _profileCard(),
            const SizedBox(height: 12),
            _fingerprintCard(),
          ] else ...[
            LoginForm(onDone: _refreshCount),
          ],
          const SizedBox(height: 12),
          _hintCard(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 已登录
  Widget _profileCard() {
    final cs = Theme.of(context).colorScheme;
    final a = AccountCtl.I;
    final initial =
        (a.name != null && a.name!.isNotEmpty) ? a.name![0].toUpperCase() : '?';
    return AppCard(
      children: [
        Row(children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: cs.primaryContainer,
            child: Text(initial,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name ?? '',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface)),
                const SizedBox(height: 3),
                Text('账号标识 ${a.uid}',
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'Consolas',
                        color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout, size: 18),
            onPressed: () async {
              await AccountCtl.I.logout();
              if (mounted) setState(() {});
            },
          ),
        ]),
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.verified_user_outlined, size: 15, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('已登录',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          SizedBox(
            height: 30,
            child: FilledButton.tonal(
              onPressed: _copyFingerprint,
              child: const Text('复制ID'),
            ),
          ),
        ]),
      ],
    );
  }

  Future<void> _copyFingerprint() async {
    await Clipboard.setData(ClipboardData(text: AccountCtl.I.fingerprint));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('ID已复制'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Widget _fingerprintCard() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      children: [
        const CardHeading(Icons.fingerprint, '用户ID'),
        const SizedBox(height: 12),
        MonoBlock(
          AccountCtl.I.fingerprint,
          size: 20,
          letterSpacing: 2,
          weight: FontWeight.w600,
          color: cs.primary,
        ),
        const SizedBox(height: 10),
        const MonoBlock('luac2c --who prog.exe'),
      ],
    );
  }

  Widget _hintCard() {
    final cs = Theme.of(context).colorScheme;
    String dir;
    try {
      dir = AccountCtl.dir;
    } catch (_) {
      dir = '';
    }
    return AppCard(
      title: '关于账号与指纹',
      icon: Icons.info_outlined,
      children: [
        InfoRow('账号库', '本机 $_users 个账号'),
        InfoRow('存储位置', dir),
        InfoRow('未登录', '暂时未对接服务器', mono: false),
        const SizedBox(height: 8),
        Text('账号数据全部留在本地；',
            style:
                TextStyle(fontSize: 12, height: 1.5, color: cs.onSurfaceVariant)),
      ],
    );
  }
}
