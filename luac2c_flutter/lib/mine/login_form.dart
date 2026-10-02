// 登录 / 注册表单（自带状态）。
//
// 账号名、密码、注册开关、忙碌态、错误信息都自己管，
// 成功后通过 [onDone] 通知外层刷新，外层不用再掺和表单细节。
import 'package:flutter/material.dart';

import '../account.dart';
import '../widgets.dart';

class LoginForm extends StatefulWidget {
  final VoidCallback onDone;
  const LoginForm({super.key, required this.onDone});

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  bool _reg = false; // false = 登录，true = 注册
  bool _obscure = true;
  bool _busy = false;
  String? _err;

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
      widget.onDone();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_reg ? '注册成功，已登录' : '登录成功'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      align: CrossAxisAlignment.stretch,
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
          Text(_reg ? '创建账号' : '登录',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
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
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
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
    );
  }
}
