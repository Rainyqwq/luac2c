// 应用外壳：标题栏 + 左侧导航。
//
// 「防护」是构建与加固的主界面，「我的」是账号与用户指纹。
// 每个界面自己不带 AppBar，标题栏由外壳统一提供。
//
// 导航从原来的底部 NavigationBar 改成左侧 rail：底部标签栏是手机习惯，
// Windows 桌面程序靠左边的导航条切换视图。顺带把 rail 收窄到 64px，
// 横竖都不挤，纵向空间也还给了内容区。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  // Windows 上 Ctrl+1 / Ctrl+2 切页，和浏览器一致
  static const _switchShortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.digit1): _SelectIntent(0),
    SingleActivator(LogicalKeyboardKey.digit2): _SelectIntent(1),
  };

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Shortcuts(
      shortcuts: _switchShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SelectIntent: CallbackAction<_SelectIntent>(
            onInvoke: (i) {
              _select(i.index);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: cs.surfaceContainerLowest,
            appBar: AppBar(
              // 标题栏左侧不再堆一个图标方块：图标已经在左侧导航的最上一格，
              // 重复一遍反而像网页的 favicon。
              title: Text(_index == 0 ? '防护' : '我的'),
              titleSpacing: 16,
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
                    transitionBuilder: (c, a) =>
                        FadeTransition(opacity: a, child: c),
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
            body: Row(
              children: [
                _NavRail(
                  index: _index,
                  onSelect: _select,
                  loggedIn: AccountCtl.I.loggedIn,
                ),
                const VerticalDivider(width: 1),
                // IndexedStack 必须给一个有限宽度，否则在 Row 里会无限撑开
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: const [HomePage(), MinePage()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectIntent extends Intent {
  final int index;
  const _SelectIntent(this.index);
}

/// 左侧导航条。只两个入口，用 rail 而不是底部标签栏。
class _NavRail extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  final bool loggedIn;
  const _NavRail(
      {required this.index,
      required this.onSelect,
      required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: AccountCtl.I,
      builder: (context, _) {
        return SizedBox(
          width: 68,
          child: Column(
            children: [
              const SizedBox(height: 8),
              _RailItem(
                icon: Icons.shield_outlined,
                activeIcon: Icons.shield,
                label: '防护',
                hotkey: '1',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              const SizedBox(height: 4),
              _RailItem(
                icon: loggedIn ? Icons.person : Icons.person_outline,
                activeIcon: Icons.person,
                label: '我的',
                hotkey: '2',
                selected: index == 1,
                onTap: () => onSelect(1),
              ),
              const Spacer(),
              // 底部放一个登录状态点，比顶部的窄条省地方
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Tooltip(
                  message: loggedIn ? '已登录，点击前往「我的」' : '未登录，点击前往「我的」',
                  child: InkWell(
                    onTap: () => onSelect(1),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        loggedIn
                            ? Icons.fingerprint
                            : Icons.person_off_outlined,
                        size: 20,
                        color: loggedIn ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String hotkey;
  final bool selected;
  final VoidCallback onTap;
  const _RailItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.hotkey,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    return Tooltip(
      // 悬停即显。Windows 靠 tooltip 说明按钮，光有图标不够。
      message: '$label  (Ctrl+$hotkey)',
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 52,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: selected ? cs.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(selected ? activeIcon : icon, size: 20, color: fg),
                const SizedBox(height: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 11, color: fg, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
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
