// 主界面（防护）：左右双栏 —— 左栏操作区，右栏运行日志。
//
// 页面本身只做两件事：把用户操作转给 [PipelineCtl]，把它的状态渲染出来。
// 所有构建/编译/运行/比对的流程逻辑都在 pipeline.dart 里。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account.dart';
import 'log_pane.dart';
import 'pipeline.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final PipelineCtl _ctl = PipelineCtl();
  static const MethodChannel _drop = MethodChannel('luac2c/drop');

  @override
  void initState() {
    super.initState();
    // 原生 runner 通过 WM_DROPFILES 把拖入的文件路径发到这个通道（支持多个）
    _drop.setMethodCallHandler((call) async {
      if (call.method == 'dropped') {
        final a = call.arguments;
        final paths = a is List
            ? a.map((e) => e.toString()).toList()
            : <String>[a.toString()];
        _ctl.addFiles(paths);
      }
      return null;
    });
    // 控制层不持有 BuildContext，提示由这里弹 SnackBar
    _ctl.onNotice = (m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating),
      );
    };
    _ctl.start();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 布局
  @override
  Widget build(BuildContext context) {
    // 左右双栏：左栏操作区可滚动，右栏是整屏高度的运行日志。
    // 原先所有卡片排在一列里，固定高度的部分把窗口占满之后，日志那个
    // Expanded 只剩 0 高度 —— 这就是"终端显示不出来"的原因。
    // 只有左栏订阅流水线状态。日志面板只依赖 LogStore —— 若把它也包进
    // 同一个监听器，每完成一个文件都要把上千行日志重新排版一遍，
    // 这就是批量处理时界面发顿的主因。
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          final left = (box.maxWidth * 0.42).clamp(320.0, 460.0);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: left,
                  child: ListenableBuilder(
                    listenable: _ctl,
                    builder: (context, _) => SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _loginStrip(),
                          const SizedBox(height: 12),
                          _sourceCard(),
                          const SizedBox(height: 12),
                          _modeSection(),
                          const SizedBox(height: 12),
                          _toolsCard(),
                          const SizedBox(height: 12),
                          _actionsSection(),
                          const SizedBox(height: 10),
                          _statusBar(),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LogPane(
                    log: _ctl.log,
                    onCopied: _ctl.noteLogCopied,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---- 登录状态 / 指纹提示 ----
  /// 主界面顶部的一条窄提示：产物到底带不带指纹，一眼能看到。
  Widget _loginStrip() {
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

  // ---- 源文件（批量列表） ----
  Widget _sourceCard() {
    final files = _ctl.files;
    final hasFiles = files.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              hasFiles ? '源文件（${files.length} 个）' : '源文件',
              icon: Icons.description_outlined,
              trailing: hasFiles
                  ? TextButton(
                      onPressed: _ctl.busy ? null : _ctl.clearFiles,
                      child: const Text('全部移除'),
                    )
                  : null,
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: hasFiles ? 132 : 46,
              child: hasFiles
                  ? _fileList()
                  : Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('点击「添加文件」多选，或把多个 .lua 文件拖进窗口',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _ctl.busy ? null : _ctl.pickFiles,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加文件（可多选）'),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: _ctl.busy
                    ? null
                    : () => _ctl.addFiles(_ctl.sampleFiles()),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('加入示例脚本'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  /// 文件列表（带每个文件的通过/失败标记与移除按钮）
  Widget _fileList() {
    final cs = Theme.of(context).colorScheme;
    final files = _ctl.files;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        itemCount: files.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: cs.outlineVariant),
        itemBuilder: (context, i) {
          final p = files[i];
          final name = p.split(r'\').last;
          final res = _ctl.results[p];
          final c = res == null
              ? cs.onSurfaceVariant
              : res
                  ? cs.primary
                  : cs.error;
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: Icon(
                res == null
                    ? Icons.description_outlined
                    : res
                        ? Icons.check_circle
                        : Icons.cancel,
                size: 18,
                color: c),
            title: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5)),
            subtitle: Text(p.substring(0, p.lastIndexOf(r'\')),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '移除',
              onPressed: _ctl.busy ? null : () => _ctl.removeFileAt(i),
            ),
          );
        },
      ),
    );
  }

  // ---- 代码布局与输出选项（M3：SegmentedButton + Switch） ----
  Widget _modeSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('代码防护', icon: Icons.tune),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment<int>(
                        value: 0, label: Text('随机'), icon: Icon(Icons.shuffle)),
                    ButtonSegment<int>(
                        value: 1, label: Text('固定种子'), icon: Icon(Icons.tag)),
                    ButtonSegment<int>(
                        value: 2,
                        label: Text('不混淆'),
                        icon: Icon(Icons.lock_open_outlined)),
                  ],
                  selected: {_ctl.mode},
                  onSelectionChanged: (s) {
                    if (!_ctl.busy) _ctl.setMode(s.first);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Opacity(
                opacity: _ctl.mode == 1 ? 1 : 0.45,
                child: SizedBox(
                  width: 78,
                  height: 40,
                  child: TextField(
                    controller: _ctl.seed,
                    enabled: !_ctl.busy && _ctl.mode == 1,
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
            Text(_ctl.modeHint,
                style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            const Divider(height: 22),
            _switchRow(
              icon: Icons.security_outlined,
              title: '运行时防护',
              subtitle: _ctl.mode == layoutPlain
                  ? '「不混淆」模式下 luac2c 不会启动防护'
                  : '注入反调试与完整性自校验，局部修改会产生静默错误',
              value: _ctl.guard && _ctl.mode != layoutPlain,
              enabled: _ctl.mode != layoutPlain,
              onChanged: _ctl.setGuard,
            ),
            const SizedBox(height: 4),
            _switchRow(
              icon: Icons.inventory_2_outlined,
              title: '关闭常量池',
              subtitle: '常量和字符将直接写进 C 源码',
              value: _ctl.noPool,
              onChanged: _ctl.setNoPool,
            ),
            const SizedBox(height: 4),
            _switchRow(
              icon: Icons.comment_outlined,
              title: '保留指令注释',
              subtitle: '在生成的 C 源码里逐条标注字节码指令',
              value: _ctl.annotate,
              onChanged: _ctl.setAnnotate,
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 18, color: cs.onSurfaceVariant),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w500)),
            const SizedBox(height: 1),
            Text(subtitle,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
      Switch(
        value: value,
        onChanged: enabled
            ? (x) {
                if (!_ctl.busy) onChanged(x);
              }
            : null,
      ),
    ]);
  }

  // ---- 工具链 ----
  Widget _toolsCard() {
    final cs = Theme.of(context).colorScheme;
    final t = _ctl.tools;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              '工具链',
              icon: Icons.build_outlined,
              trailing: t.allOk
                  ? const StatusDot(ok: true, label: '就绪', path: '所有工具已找到')
                  : const StatusDot(
                      ok: false, label: '有缺失', path: '见下方指示灯'),
            ),
            const SizedBox(height: 10),
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
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'Consolas')),
            if (!t.allOk) ...[
              const SizedBox(height: 6),
              Text(
                '自动探测未找齐。可用环境变量 LUAC / LUAC2C / LUA / GCC 指定，'
                '或在程序目录的 luac2c_gui.ini 里配置 [paths] 段。',
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- 操作按钮（M3：FilledButton 主操作 / OutlinedButton 次操作） ----
  Widget _actionsSection() {
    return Column(children: [
      Row(children: [
        Expanded(
          child: Tooltip(
            message: '编译字节码 → 转译为 C → gcc 编译 → 运行生成物',
            child: FilledButton.icon(
              onPressed: _ctl.busy ? null : () => _ctl.run(full: true),
              icon: _ctl.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 20),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('一键构建', style: TextStyle(fontSize: 15)),
              ),
            ),
          ),
        ),
        if (_ctl.busy) ...[
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: _ctl.stop,
            icon: const Icon(Icons.stop, size: 18),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('停止', style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ]),
      if (_ctl.busy) ...[
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _ctl.totalCount == 0 ? null : _ctl.doneCount / _ctl.totalCount,
            minHeight: 6,
          ),
        ),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
            child: _minorButton(Icons.description_outlined, '仅生成 C 源码',
                () => _ctl.run(full: false),
                tip: '仅生成 C 源码，不运行')),
        const SizedBox(width: 10),
        Expanded(
            child: _minorButton(Icons.build_outlined, '重新编译 luac2c',
                _ctl.rebuild,
                tip: '用 gcc 重新编译 luac2c.c，生成新的 luac2c.exe')),
        const SizedBox(width: 10),
        Expanded(
            child: _minorButton(Icons.folder_open_outlined, '打开输出目录',
                _ctl.openOutDir,
                tip: '在资源管理器中打开源文件所在目录')),
      ]),
    ]);
  }

  Widget _minorButton(IconData icon, String label, VoidCallback onTap,
      {String? tip}) {
    final btn = OutlinedButton.icon(
      onPressed: _ctl.busy ? null : onTap,
      icon: Icon(icon, size: 16),
      label: Flexible(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5)),
      ),
    );
    return tip == null ? btn : Tooltip(message: tip, child: btn);
  }

  // ---- 状态条（M3：容器色 + onContainer 前景色） ----
  Widget _statusBar() {
    final cs = Theme.of(context).colorScheme;
    final s = _ctl.status;
    final ok = s.startsWith('通过') ||
        s.startsWith('批量通过') ||
        s.contains('已重新编译') ||
        s.contains('已复制');
    final bad =
        s.startsWith('失败') || s.startsWith('不一致') || s.endsWith('失败');
    final bg = bad
        ? cs.errorContainer
        : ok
            ? cs.primaryContainer
            : cs.surfaceContainerHighest;
    final fg = bad
        ? cs.onErrorContainer
        : ok
            ? cs.onPrimaryContainer
            : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(
            bad
                ? Icons.error_outline
                : ok
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
            size: 18,
            color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Text(s,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
        ),
        if (_ctl.busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          ),
      ]),
    );
  }
}
