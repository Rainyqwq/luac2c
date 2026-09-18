// luac2c 客户端 (Flutter Windows Desktop, Material You / Material Design 3)
//
// 与 Win32 原生版 luac2c_gui.c 功能一致：
//   一键流水线: luac.exe -> luac2c.exe -> gcc -> 运行生成物 -> 与 lua.exe 输出比对
//   仅翻译 C / 重建 luac2c.exe / 三种模式 + --no-pool / --annotate
//   拖拽 .lua 文件（runner 原生 WM_DROPFILES）、日志窗格、luac2c_gui.ini [paths] 路径覆盖
//
// 设计规范：Material Design 3（Material You）—— 全部配色来自 ColorScheme.fromSeed
// 生成的种子配色方案，组件一律用 M3 组件（SegmentedButton / FilledButton / Switch /
// NavigationBar / Card / SnackBar），明暗双主题，状态层用 surfaceContainer 系列。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeCtl.I.load();
  runApp(const Luac2cApp());
}

// ---------------------------------------------------------------- 主题控制
/// 明暗 + 种子色状态（持久化到 exe 同目录的 client_prefs.txt）
class ThemeCtl extends ChangeNotifier {
  ThemeCtl._();
  static final ThemeCtl I = ThemeCtl._();

  bool dark = false;
  int seedIndex = 0;

  /// Material You 的几套种子色（蓝 / 青 / 紫 / 绿 / 橙）
  static const seeds = <Color>[
    Color(0xFF00639B), // Blue（默认）
    Color(0xFF00696E), // Teal
    Color(0xFF6B4EFF), // Violet
    Color(0xFF386A20), // Green
    Color(0xFF984100), // Orange
  ];

  Color get seed => seeds[seedIndex];

  Future<void> load() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exeDir\\client_prefs.txt');
      if (f.existsSync()) {
        final t = (await f.readAsString()).trim();
        for (final kv in t.split(';')) {
          final p = kv.split('=');
          if (p.length != 2) continue;
          if (p[0] == 'dark') dark = p[1] == '1';
          if (p[0] == 'seed') seedIndex = int.tryParse(p[1])?.clamp(0, 4) ?? 0;
        }
      }
    } catch (_) {/* 读取失败用默认值 */}
  }

  Future<void> _save() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      await File('$exeDir\\client_prefs.txt')
          .writeAsString('dark=${dark ? 1 : 0};seed=$seedIndex');
    } catch (_) {/* 写失败不影响运行 */}
  }

  Future<void> set(bool d) async {
    if (dark == d) return;
    dark = d;
    notifyListeners();
    await _save();
  }

  void toggle() => set(!dark);

  /// 切换 Material You 种子配色
  Future<void> cycleSeed() async {
    seedIndex = (seedIndex + 1) % seeds.length;
    notifyListeners();
    await _save();
  }
}

// ---------------------------------------------------------------- Material You 主题
class AppTheme {
  /// 由种子色生成完整 M3 配色方案（Material You 的核心：一套种子 → 整套角色色）
  static ColorScheme scheme(Brightness b, Color seed) =>
      ColorScheme.fromSeed(seedColor: seed, brightness: b);

  static ThemeData build(Brightness b, Color seed) {
    final cs = scheme(b, seed);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      // Windows 上保证中文正常显示
      fontFamily: 'Microsoft YaHei UI',
      visualDensity: VisualDensity.standard,
      // M3 动效规范：emphasized 减速曲线
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 3,
        backgroundColor: cs.surface,
        surfaceTintColor: cs.surfaceTint,
        foregroundColor: cs.onSurface,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surfaceContainerLow,
        surfaceTintColor: cs.surfaceTint,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: cs.outlineVariant, thickness: 1),
    );
  }
}

class Luac2cApp extends StatelessWidget {
  const Luac2cApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeCtl.I,
      builder: (context, _) => MaterialApp(
        title: 'luac2c 客户端',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Brightness.light, ThemeCtl.I.seed),
        darkTheme: AppTheme.build(Brightness.dark, ThemeCtl.I.seed),
        themeMode: ThemeCtl.I.dark ? ThemeMode.dark : ThemeMode.light,
        home: const HomePage(),
      ),
    );
  }
}

// ---------------------------------------------------------------- 工具解析
class Tools {
  String luac = '', l2c = '', lua = '', gcc = '';
  String inc1 = '', inc2 = '', lib = '';
  String root = '';

  bool get luacOk => File(luac).existsSync();
  bool get l2cOk => File(l2c).existsSync();
  bool get luaOk => File(lua).existsSync();
  bool get gccOk => File(gcc).existsSync();
  bool get allOk => luacOk && l2cOk && luaOk && gccOk;
}

Tools findTools() {
  final t = Tools();
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  // 默认根目录：exe 所在目录 -> 项目根（可被 ini 覆盖）
  const projectRoot = r'C:\Users\Rainy\Desktop\Project\Luac2c';
  t.root = File('$exeDir\\luac.exe').existsSync() ? exeDir : projectRoot;

  // 查找顺序：exe 同目录 -> 根目录 -> 固定位置 -> 系统 PATH 环境变量
  String resolve(String name, {String? fixed}) {
    final cands = <String>[
      '$exeDir\\$name.exe',
      '${t.root}\\$name.exe',
      ?fixed,
      ..._fromPathEnv(name),
    ];
    for (final c in cands) {
      if (File(c).existsSync()) return c;
    }
    return '${t.root}\\$name.exe'; // 兜底，运行时报错可见
  }

  t.luac = resolve('luac');
  t.l2c = resolve('luac2c');
  t.lua = resolve('lua');
  t.gcc = resolve('gcc', fixed: r'C:\environments\GCC-16.2.0\bin\gcc.exe');
  t.inc1 = '${t.root}\\lua-5.5.1\\src';
  t.inc2 = '${t.root}\\lua5.5-include';
  t.lib = '${t.root}\\lua-5.5.1\\build\\liblua.a';

  // luac2c_gui.ini 的 [paths] 段可覆盖
  final ini = File('$exeDir\\luac2c_gui.ini');
  if (ini.existsSync()) {
    var inPaths = false;
    final map = <String, String>{};
    for (final raw in ini.readAsLinesSync()) {
      final line = raw.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        inPaths = line.substring(1, line.length - 1).toLowerCase() == 'paths';
        continue;
      }
      if (!inPaths) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final k = line.substring(0, eq).trim().toLowerCase();
      final v = line.substring(eq + 1).trim();
      if (v.isNotEmpty) map[k] = v;
    }
    String ov(String key, String cur) {
      final v = map[key];
      return (v == null || v.isEmpty) ? cur : v.replaceAll('/', r'\');
    }

    t.luac = ov('luac', t.luac);
    t.l2c = ov('luac2c', t.l2c);
    t.lua = ov('lua', t.lua);
    t.gcc = ov('gcc', t.gcc);
    t.inc1 = ov('inc1', t.inc1);
    t.inc2 = ov('inc2', t.inc2);
    t.lib = ov('lib', t.lib);
    final r = map['root'];
    if (r != null && r.isNotEmpty) t.root = r;
  }
  return t;
}

// ---------------------------------------------------------------- 流程执行
class StepResult {
  final int exitCode;
  final String output;
  StepResult(this.exitCode, this.output);
}

Future<StepResult> runCapture(String exe, List<String> args, String? cwd) async {
  try {
    final p =
        await Process.start(exe, args, workingDirectory: cwd, runInShell: false);
    final out = <String>[];
    final done = <Future>[];
    done.add(p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(out.add));
    done.add(p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(out.add));
    await Future.wait(done);
    final code = await p.exitCode;
    return StepResult(code, out.join('\n'));
  } catch (e) {
    return StepResult(-1, e.toString());
  }
}

/// 从系统 PATH 环境变量里枚举某工具的候选路径
List<String> _fromPathEnv(String name) {
  final pathEnv = Platform.environment['PATH'] ?? '';
  final out = <String>[];
  for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
    if (dir.trim().isEmpty) continue;
    out.add('${dir.trim()}\\$name.exe');
  }
  return out;
}

String trimTail(String s) => s.replaceFirst(RegExp(r'[\s]+$'), '');

// ---------------------------------------------------------------- 通用组件
/// 卡片内小标题
class SectionTitle extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
      ],
      Text(text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: cs.primary,
              letterSpacing: 0.2)),
      const Spacer(),
      ?trailing,
    ]);
  }
}

/// 工具状态指示灯（M3：error / primary 容器配色）
class StatusDot extends StatelessWidget {
  final bool ok;
  final String label;
  final String path;
  const StatusDot(
      {super.key, required this.ok, required this.label, required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: path,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: ok ? cs.primaryContainer : cs.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok ? Icons.check_circle : Icons.error,
              size: 13, color: ok ? cs.onPrimaryContainer : cs.onErrorContainer),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: ok ? cs.onPrimaryContainer : cs.onErrorContainer)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- 主界面
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _seed = TextEditingController(text: '0');
  final ScrollController _logScroll = ScrollController();
  final List<String> _logLines = [];
  // 批量处理：待处理文件列表 + 每个文件的结果
  final List<String> _files = <String>[];
  final Map<String, bool> _results = <String, bool>{};
  int _doneCount = 0, _totalCount = 0;
  Tools _tools = Tools();
  int _mode = 0; // 0 多样化 1 指定种子 2 --static
  bool _nopool = false, _annot = false, _busy = false;
  String _status = '就绪';
  Timer? _toolsTimer;
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
        _addFiles(paths);
      }
      return null;
    });
    _toolsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final t = findTools();
      if (mounted && t.allOk != _tools.allOk) {
        setState(() => _tools = t);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() => _tools = findTools());
      log('工具链探测完成。选择 .lua 文件，或直接把文件拖进窗口。');
    });
  }

  @override
  void dispose() {
    _toolsTimer?.cancel();
    _seed.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// 把外部给进来的路径加入待处理列表（去重、只收存在的文件）
  void _addFiles(List<String> paths) {
    if (!mounted) return;
    var added = 0;
    setState(() {
      for (final p in paths) {
        final t = p.trim();
        if (t.isEmpty) continue;
        if (!File(t).existsSync()) continue;
        if (_files.contains(t)) continue;
        _files.add(t);
        added++;
      }
    });
    if (added > 0) log('已添加 $added 个文件（当前共 ${_files.length} 个）');
  }

  void log(String s) {
    if (!mounted) return;
    setState(() => _logLines.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  void setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  /// 多选文件（Windows 文件对话框，Multiselect）
  Future<void> pickFile() async {
    final r = await runCapture(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms;'
              '\$f = New-Object System.Windows.Forms.OpenFileDialog;'
              '\$f.Multiselect = \$true;'
              '\$f.Filter = "Lua 源文件(*.lua;*.luac)|*.lua;*.luac|所有文件(*.*)|*.*";'
              'if (\$f.ShowDialog() -eq "OK") { \$f.FileNames | ForEach-Object { Write-Output \$_ } }'
        ],
        null);
    final lines = r.output
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (r.exitCode == 0 && lines.isNotEmpty) _addFiles(lines);
  }

  void openOutDir() {
    final p = _files.isNotEmpty ? _files.first : '';
    final dir =
        p.contains(r'\') ? p.substring(0, p.lastIndexOf(r'\')) : _tools.root;
    Process.run('explorer.exe', [dir]);
  }

  Future<void> copyLog() async {
    await Clipboard.setData(ClipboardData(text: _logLines.join('\n')));
    setStatus('日志已复制到剪贴板');
  }

  List<String> l2cArgs(String luacPath, String outC) {
    final args = <String>[luacPath];
    if (_mode == 1) {
      args.addAll(
          ['--seed', _seed.text.trim().isEmpty ? '0' : _seed.text.trim()]);
    }
    if (_mode == 2) args.add('--static');
    args.addAll(['-o', outC]);
    if (_nopool) args.add('--no-pool');
    if (_annot) args.add('--annotate');
    return args;
  }

  // ---- 批量流水线 ----
  Future<void> runPipeline({required bool full}) async {
    if (_busy) return;
    if (_files.isEmpty) {
      await _msg('请先添加 .lua 文件（可多选，或把多个文件拖进窗口）');
      return;
    }
    if (!_tools.l2cOk) {
      await _msg('找不到 luac2c.exe（根目录：${_tools.root}，已尝试 PATH）');
      return;
    }
    setState(() {
      _busy = true;
      _results.clear();
      _totalCount = _files.length;
      _doneCount = 0;
    });
    var pass = 0;
    for (final f in _files) {
      final ok = await _processOne(f, full);
      if (ok) pass++;
      setState(() {
        _doneCount++;
        _results[f] = ok;
      });
      setStatus('进度 $_doneCount/$_totalCount —— 已通过 $pass');
    }
    final failed = _totalCount - pass;
    setState(() => _busy = false);
    setStatus(failed == 0
        ? '批量通过：$pass/$_totalCount'
        : '批量完成：$pass 通过，$failed 失败');
    log(failed == 0
        ? '✓ 批量全部通过（$pass/$_totalCount）'
        : '✗ 批量结束：失败 $failed 个');
  }

  /// 处理单个文件，返回是否通过
  Future<bool> _processOne(String srcPath, bool full) async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    log('');
    log('──── ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $srcPath');
    final dir = srcPath.contains(r'\')
        ? srcPath.substring(0, srcPath.lastIndexOf(r'\'))
        : Directory.current.path;
    final base = srcPath.split(r'\').last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final pLuac = '$dir\\$stem.luac';
    final pC = '$dir\\${stem}_out.c';
    final pExe = '$dir\\${stem}_out.exe';

    try {
      log('[1/5] luac  编译字节码');
      if (!_tools.luacOk) throw '找不到 luac.exe（[paths] luac = ${_tools.luac}）';
      var r = await runCapture(_tools.luac, ['-o', pLuac, srcPath], dir);
      _logOut(r);
      if (r.exitCode != 0) throw 'luac 退出码 ${r.exitCode}';
      log('      → $pLuac');

      log('[2/5] luac2c  翻译为 C');
      r = await runCapture(_tools.l2c, l2cArgs(pLuac, pC), dir);
      _logOut(r);
      if (r.exitCode != 0) throw 'luac2c 退出码 ${r.exitCode}';
      log('      → $pC');
      if (!full) {
        log('✓ 仅翻译完成 → $pC');
        return true;
      }

      log('[3/5] gcc  编译链接');
      if (!_tools.gccOk) throw '找不到 gcc.exe（[paths] gcc = ${_tools.gcc}）';
      r = await runCapture(
          _tools.gcc,
          [
            pC,
            '-I',
            _tools.inc1,
            '-I',
            _tools.inc2,
            '-std=c99',
            '-w',
            '-O0',
            '-o',
            pExe,
            _tools.lib,
            '-lm'
          ],
          dir);
      _logOut(r);
      if (r.exitCode != 0) throw 'gcc 退出码 ${r.exitCode}';
      log('      → $pExe');

      log('[4/5] 运行生成物');
      final gen = await runCapture(pExe, [], dir);

      log('[5/5] 与 lua.exe 输出比对');
      if (!_tools.luaOk) throw '找不到 lua.exe（[paths] lua = ${_tools.lua}）';
      final ref = await runCapture(_tools.lua, [srcPath], dir);
      final genOut = trimTail(gen.output);
      final refOut = trimTail(ref.output);
      if (genOut.isNotEmpty) {
        log('      生成物> ${genOut.replaceAll('\n', '\n      ')}');
      }
      if (refOut.isNotEmpty) {
        log('      lua.exe> ${refOut.replaceAll('\n', '\n      ')}');
      }
      final same = genOut == refOut && gen.exitCode == ref.exitCode;
      if (same) {
        log('      ✓ 输出一致，退出码一致 (${gen.exitCode})');
        log('✓ 通过：$srcPath');
        return true;
      } else {
        log('      ✗ 不一致（exit ${gen.exitCode} vs ${ref.exitCode}）');
        log('✗ 失败：$srcPath');
        return false;
      }
    } catch (e) {
      log('      ✗ $e');
      log('✗ 失败：$srcPath');
      return false;
    }
  }

  Future<void> rebuildLuac2c() async {
    if (_busy) return;
    setState(() => _busy = true);
    log('');
    log('[重建] gcc luac2c.c -O2 -o luac2c.exe');
    try {
      if (!_tools.gccOk) throw '找不到 gcc.exe';
      final r = await runCapture(
          _tools.gcc,
          [
            '${_tools.root}\\luac2c.c',
            '-O2',
            '-o',
            '${_tools.root}\\luac2c.exe',
            '-lm'
          ],
          _tools.root);
      _logOut(r);
      if (r.exitCode == 0) {
        log('      ✓ luac2c.exe 已重建');
        setStatus('luac2c.exe 已重建');
      } else {
        log('      ✗ gcc 退出码 ${r.exitCode}');
        setStatus('重建失败');
      }
    } catch (e) {
      log('      ✗ $e');
      setStatus('重建失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _logOut(StepResult r) {
    if (r.output.trim().isNotEmpty) {
      log('      ${r.output.trim().replaceAll('\n', '\n      ')}');
    }
  }

  Future<void> _msg(String m) async {
    log('! $m');
    setStatus(m);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating),
      );
    }
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    // Material You：配色全部来自 ColorScheme，组件用 M3 组件
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
            child: Icon(Icons.code, size: 16, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          const Text('luac2c 客户端'),
        ]),
        actions: [
          // Material You 种子配色切换
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: '切换配色（Material You 种子色）',
            onPressed: () => ThemeCtl.I.cycleSeed(),
          ),
          // 明暗主题
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
            onPressed: _showAbout,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sourceCard(),
                  const SizedBox(height: 12),
                  _modeSection(),
                  const SizedBox(height: 12),
                  _toolsCard(),
                  const SizedBox(height: 12),
                  _actionsSection(),
                  const SizedBox(height: 10),
                  _statusBar(),
                  const SizedBox(height: 10),
                  Expanded(child: _logCard()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 源文件（批量列表） ----
  Widget _sourceCard() {
    final hasFiles = _files.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              hasFiles ? '源文件（${_files.length} 个）' : '源文件',
              icon: Icons.description_outlined,
              trailing: hasFiles
                  ? TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _files.clear();
                                _results.clear();
                              _doneCount = 0;
                              _totalCount = 0;
                            }),
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
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : pickFile,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加文件（可多选）'),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => _addFiles(_sampleFiles()),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('加入示例'),
            ),
          ]),
        ],
      ),
      ),
    );
  }

  /// 项目 test 目录下的用例（方便一键批量试跑）
  List<String> _sampleFiles() {
    final d = Directory('${_tools.root}\\test');
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.lua'))
        .map((f) => f.path)
        .toList();
  }

  /// 文件列表（带每个文件的通过/失败标记与移除按钮）
  Widget _fileList() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        itemCount: _files.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: cs.outlineVariant),
        itemBuilder: (context, i) {
          final p = _files[i];
          final name = p.split(r'\').last;
          final res = _results[p];
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
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _files.removeAt(i);
                        _results.remove(p);
                      }),
            ),
          );
        },
      ),
    );
  }

  // ---- 翻译模式与选项（M3：SegmentedButton + Switch） ----
  Widget _modeSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('翻译模式', icon: Icons.tune),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment<int>(
                        value: 0,
                        label: Text('默认多样化'),
                        icon: Icon(Icons.shuffle)),
                    ButtonSegment<int>(
                        value: 1, label: Text('指定种子'), icon: Icon(Icons.tag)),
                    ButtonSegment<int>(
                        value: 2,
                        label: Text('--static'),
                        icon: Icon(Icons.lock_outline)),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) {
                    if (!_busy) setState(() => _mode = s.first);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Opacity(
                opacity: _mode == 1 ? 1 : 0.45,
                child: SizedBox(
                  width: 78,
                  height: 40,
                  child: TextField(
                    controller: _seed,
                    enabled: !_busy && _mode == 1,
                    decoration: const InputDecoration(
                      labelText: 'seed',
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
            const SizedBox(height: 6),
            const Divider(height: 22),
            _switchRow(
              icon: Icons.inventory_2_outlined,
              title: '--no-pool',
              subtitle: '关闭常量池，字面量直接进源码，便于调试',
              value: _nopool,
              onChanged: (v) => _nopool = v,
            ),
            const SizedBox(height: 4),
            _switchRow(
              icon: Icons.comment_outlined,
              title: '--annotate',
              subtitle: '在生成的 C 代码中保留 opcode 注释',
              value: _annot,
              onChanged: (v) => _annot = v,
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
        onChanged: (x) {
          if (!_busy) setState(() => onChanged(x));
        },
      ),
    ]);
  }

  // ---- 工具链 ----
  Widget _toolsCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              '工具链',
              icon: Icons.build_outlined,
              trailing: _tools.allOk
                  ? const StatusDot(ok: true, label: '就绪', path: '全部工具已找到')
                  : const StatusDot(
                      ok: false, label: '有缺失', path: '见下方指示灯'),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              StatusDot(ok: _tools.luacOk, label: 'luac', path: _tools.luac),
              StatusDot(ok: _tools.l2cOk, label: 'luac2c', path: _tools.l2c),
              StatusDot(ok: _tools.luaOk, label: 'lua', path: _tools.lua),
              StatusDot(ok: _tools.gccOk, label: 'gcc', path: _tools.gcc),
            ]),
            const SizedBox(height: 10),
            Text(_tools.root,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'Consolas')),
          ],
        ),
      ),
    );
  }

  // ---- 操作按钮（M3：FilledButton 主操作 / OutlinedButton 次操作） ----
  Widget _actionsSection() {
    return Column(children: [
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _busy ? null : () => runPipeline(full: true),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow, size: 20),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('一键流水线', style: TextStyle(fontSize: 15)),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
            child: _minorButton(Icons.description_outlined, '仅翻译 C',
                () => runPipeline(full: false))),
        const SizedBox(width: 10),
        Expanded(
            child: _minorButton(
                Icons.build_outlined, '重建 luac2c', rebuildLuac2c)),
        const SizedBox(width: 10),
        Expanded(
            child: _minorButton(Icons.folder_open_outlined, '输出目录', openOutDir)),
      ]),
    ]);
  }

  Widget _minorButton(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 16),
      label: Flexible(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5)),
      ),
    );
  }

  // ---- 状态条（M3：容器色 + onContainer 前景色） ----
  Widget _statusBar() {
    final cs = Theme.of(context).colorScheme;
    final ok = _status.startsWith('通过') ||
        _status.startsWith('翻译完成') ||
        _status.contains('已重建') ||
        _status.contains('已复制');
    final bad = _status.startsWith('失败') || _status.startsWith('不一致');
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
          child: Text(_status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
        ),
        if (_busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        else if (_logLines.isNotEmpty)
          Text('${_logLines.length} 行',
              style: TextStyle(fontSize: 11, color: fg)),
      ]),
    );
  }

  // ---- 日志（M3：surface 容器 + 等宽字体） ----
  Widget _logCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 4),
            child: Row(children: [
              Icon(Icons.terminal, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('输出日志',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const Spacer(),
              TextButton.icon(
                onPressed: copyLog,
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text('复制'),
              ),
              TextButton.icon(
                onPressed: () => setState(_logLines.clear),
                icon: const Icon(Icons.delete_outline, size: 15),
                label: const Text('清空'),
              ),
            ]),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            child: Scrollbar(
              controller: _logScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _logScroll,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _logLines.isEmpty ? '（暂无输出）' : _logLines.join('\n'),
                  style: TextStyle(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: const ['Microsoft YaHei UI'],
                      fontSize: 12,
                      height: 1.45,
                      color: cs.onSurface),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.code),
        title: const Text('luac2c 客户端'),
        content: SizedBox(
          width: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('把 Lua 5.5 字节码翻译成调用 Lua C API 的 C 源码，'
                  '并一键编译、运行、与 lua.exe 逐字节比对。'),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              _aboutRow('根目录', _tools.root),
              _aboutRow('luac', _tools.luac),
              _aboutRow('luac2c', _tools.l2c),
              _aboutRow('lua', _tools.lua),
              _aboutRow('gcc', _tools.gcc),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好')),
        ],
      ),
    );
  }

  Widget _aboutRow(String k, String v) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 62,
            child: Text(k, style: TextStyle(fontSize: 12, color: cs.primary))),
        Expanded(
            child: Text(v,
                style: const TextStyle(fontSize: 11.5, fontFamily: 'Consolas'))),
      ]),
    );
  }
}
