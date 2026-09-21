// 应用外壳：统一标题栏 + 底部导航栏（M3 NavigationBar）在两个界面间切换。
//
// 「防护」是构建与加固的主界面，「我的」是账号与用户指纹。
// 每个界面自己不带 AppBar，标题栏由外壳统一提供。
import 'package:flutter/material.dart';

import 'account.dart';
import 'home_page.dart';
import 'mine_page.dart';
import 'theme.dart';
import 'tools.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(_index == 0 ? Icons.shield_outlined : Icons.person_outline,
                size: 16, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          const Text('luac2c For Windows'),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: '切换配色',
            onPressed: () => ThemeCtl.I.cycleSeed(),
          ),
          IconButton(
            tooltip: ThemeCtl.I.dark ? '切换到浅色' : '切换到深色',
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
              child: Icon(
                key: ValueKey<bool>(ThemeCtl.I.dark),
                ThemeCtl.I.dark ? Icons.light_mode : Icons.dark_mode,
              ),
            ),
            onPressed: () => ThemeCtl.I.toggle(),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '关于',
            onPressed: () => showAbout(context),
          ),
          const SizedBox(width: 6),
        ],
      ),
      // IndexedStack 保留两个界面的状态：切走再切回来，日志和列表都还在。
      body: IndexedStack(
        index: _index,
        children: const [HomePage(), MinePage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: '防护',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

/// 关于对话框：把工具链解析结果与当前账号一并列出，便于排查环境问题
void showAbout(BuildContext context) {
  final t = findTools();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.code),
      title: const Text('luac2c For Windows'),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('把 Lua 5.5 字节码翻译成等效 C 源码，'
                '2026 Rainy_qwq 荣誉出品'),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            _aboutRow(context, '根目录', t.root),
            _aboutRow(context, 'luac地址', t.luac),
            _aboutRow(context, '主程序地址', t.l2c),
            _aboutRow(context, 'lua地址', t.lua),
            _aboutRow(context, 'C编译器地址', t.gcc),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            _aboutRow(context, '账号', AccountCtl.I.loggedIn
                ? '${AccountCtl.I.name}（ID ${AccountCtl.I.fingerprint}）'
                : '当前未登录'),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('好')),
      ],
    ),
  );
}

Widget _aboutRow(BuildContext context, String k, String v) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
          width: 80,
          child: Text(k, style: TextStyle(fontSize: 12, color: cs.primary))),
      Expanded(
          child: Text(v,
              style: const TextStyle(fontSize: 11.5, fontFamily: 'Consolas'))),
    ]),
  );
}
