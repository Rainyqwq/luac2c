// 「我的」页面：本地账号登录 + 用户指纹
//
// 登录后客户端把 uid 传给 luac2c（--fingerprint），产物里就带上这个账号的
// 指纹。拿到一份分发出去的副本，跑
//     luac2c --who prog.exe
// 就能查到它是谁的。指纹只是 uid 折出来的一个 32 位数，
// 二进制里没有明文账号，也没有可识别的水印串。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  bool _reg = false; // false = 登录，true = 注册
  bool _obscure = true;
  bool _busy = false;
  String? _err;
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
  void dispose() {
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    String? err;
    try {
      err = _reg
          ? await AccountCtl.I.register(_user.text, _pwd.text)
          : await AccountCtl.I.login(_user.text, _pwd.text);
    } catch (e) {
      // 任何落盘/解析异常都要落到界面上，绝不能让按钮永远转圈
      err = '操作失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _err = err;
    });
    if (err == null) {
      _pwd.clear();
      _refreshCount();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_reg ? '注册成功，已登录' : '登录成功，产物将带上你的指纹'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
            _loginCard(),
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
    final initial = (a.name != null && a.name!.isNotEmpty)
        ? a.name![0].toUpperCase()
        : '?';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                  if (mounted) setState(() => _reg = false);
                },
              ),
            ]),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.verified_user_outlined,
                  size: 15, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已登录 · 之后构建的产物都会嵌入这个账号的指纹',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
              SizedBox(
                height: 30,
                child: FilledButton.tonal(
                  onPressed: _copyFingerprint,
                  child: const Text('复制指纹'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _copyFingerprint() async {
    await Clipboard.setData(ClipboardData(text: AccountCtl.I.fingerprint));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('指纹已复制'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Widget _fingerprintCard() {
    final cs = Theme.of(context).colorScheme;
    final fp = AccountCtl.I.fingerprint;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.fingerprint, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text('用户指纹',
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ]),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                fp,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 20,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '由账号标识折叠出来的 32 位数。构建时它会写入产物，'
              '并且参与常量池密钥——改动它，程序就会跑在错误的数据上。',
              style: TextStyle(fontSize: 12, height: 1.5, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                'luac2c --who prog.exe',
                style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 6),
            Text('用上面这条命令可以从任意一份产物里把指纹读出来，反查归属。',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 登录 / 注册
  Widget _loginCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.lock_open_outlined,
                    size: 18, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_reg ? '创建账号' : '登录',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface)),
                    Text(
                      _reg
                          ? '注册后即可为产物打上你的指纹'
                          : '登录后构建的产物会带上你的指纹',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('登录')),
                ButtonSegment(value: true, label: Text('注册')),
              ],
              selected: {_reg},
              onSelectionChanged: (s) => setState(() {
                _reg = s.first;
                _err = null;
              }),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _user,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '账号',
                hintText: '用户名',
                prefixIcon: Icon(Icons.person_outline, size: 18),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pwd,
              enabled: !_busy,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '密码',
                hintText: _reg ? '至少 6 位' : '',
                prefixIcon: const Icon(Icons.lock_outline, size: 18),
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 18),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              SizedBox(
                height: 32,
                width: 32,
                child: Checkbox(
                  value: AccountCtl.I.remember,
                  onChanged: (v) => AccountCtl.I.setRemember(v ?? true),
                ),
              ),
              const Text('记住我', style: TextStyle(fontSize: 12.5)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _reg = true;
                  _err = null;
                }),
                child: const Text('还没有账号？注册'),
              ),
            ]),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Icon(Icons.error_outline, size: 15, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_err!,
                        style: TextStyle(fontSize: 12.5, color: cs.error)),
                  ),
                ]),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_reg ? '注册并登录' : '登录'),
            ),
          ],
        ),
      ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('关于账号与指纹',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ]),
            const SizedBox(height: 10),
            _row('账号库', '本机 $_users 个账号'),
            _row('存储位置', dir),
            _row('口令', '只保存 salt 后的 SHA-256，不存明文'),
            _row('未登录', '仍可正常构建，只是产物不带指纹'),
            const SizedBox(height: 8),
            Text(
              '账号数据全部留在本机（不联网、无服务端）；'
              '指纹只用于追溯分发出去的副本属于谁。',
              style: TextStyle(fontSize: 12, height: 1.5, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 72,
            child: Text(k, style: TextStyle(fontSize: 12, color: cs.primary))),
        Expanded(
          child: Text(v,
              style: const TextStyle(fontSize: 11.5, fontFamily: 'Consolas')),
        ),
      ]),
    );
  }
}
