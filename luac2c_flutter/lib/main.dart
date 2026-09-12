// luac2c 客户端 (Flutter Windows Desktop, Cupertino / iOS 设计风格)
//
// 与 Win32 原生版 luac2c_gui.c 功能一致：
//   一键流水线: luac.exe -> luac2c.exe -> gcc -> 运行生成物 -> 与 lua.exe 输出比对
//   仅翻译 C / 重建 luac2c.exe / 三种模式 + --no-pool / --annotate
//   拖拽 .lua 文件（runner 原生 WM_DROPFILES）、日志窗格、luac2c_gui.ini [paths] 路径覆盖
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
// 以下三个仅存在于 material：日志可选中文本、悬浮提示、分隔线
import 'package:flutter/material.dart' show SelectableText, Tooltip, Divider;
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeCtl.I.load();
  runApp(const Luac2cApp());
}

// ---------------------------------------------------------------- 主题控制
/// 明暗主题状态（持久化到 exe 同目录的 client_prefs.txt）
class ThemeCtl extends ChangeNotifier {
  ThemeCtl._();
  static final ThemeCtl I = ThemeCtl._();

  bool dark = false;

  Future<void> load() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exeDir\\client_prefs.txt');
      if (f.existsSync()) {
        dark = (await f.readAsString()).trim() == 'dark=1';
      }
    } catch (_) {/* 读取失败用默认值 */}
  }

  Future<void> set(bool d) async {
    if (dark == d) return;
    dark = d;
    notifyListeners();
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      await File('$exeDir\\client_prefs.txt')
          .writeAsString(d ? 'dark=1' : 'dark=0');
    } catch (_) {/* 写失败不影响运行 */}
  }

  void toggle() => set(!dark);
}

// ---------------------------------------------------------------- Liquid Glass 调色板
class Glass {
  static bool get dark => ThemeCtl.I.dark;

  // 页面底色（模糊与折射感知的底）
  static Color get pageTop => dark ? const Color(0xFF101018) : const Color(0xFFEEF1F8);
  static Color get pageBottom => dark ? const Color(0xFF050508) : const Color(0xFFE2E6F0);

  // 背景色斑（液态玻璃的"折射源"）
  static Color get blob1 => dark
      ? CupertinoColors.systemIndigo.withValues(alpha: 0.35)
      : CupertinoColors.systemBlue.withValues(alpha: 0.30);
  static Color get blob2 => dark
      ? CupertinoColors.systemPurple.withValues(alpha: 0.28)
      : CupertinoColors.systemPurple.withValues(alpha: 0.22);
  static Color get blob3 => dark
      ? CupertinoColors.systemTeal.withValues(alpha: 0.22)
      : CupertinoColors.systemPink.withValues(alpha: 0.20);

  // 玻璃卡片
  static Color get cardFill => dark
      ? const Color(0x14FFFFFF)
      : const Color(0x99FFFFFF);
  static Color get cardEdge => dark
      ? const Color(0x2EFFFFFF)
      : const Color(0x73FFFFFF);
  static Color get cardGloss => dark
      ? const Color(0x1FFFFFFF)
      : const Color(0x55FFFFFF);
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
            color: dark ? const Color(0x66000000) : const Color(0x1A000000),
            blurRadius: 20,
            offset: const Offset(0, 8)),
      ];

  static Color get title => dark
      ? CupertinoColors.systemGrey
      : const Color(0xFF6D6D72);

  // 日志终端（两种模式都保持深色控制台，暗色下更深）
  static Color get logBg => dark ? const Color(0xFF101014) : const Color(0xFF1C1C1E);
  static const Color logFg = Color(0xFFE8E8ED);
  static Color get logBorder => dark ? const Color(0xFF2C2C30) : const Color(0xFF3A3A3C);

  static Color get segThumb => dark ? const Color(0xFF5A5A60) : CupertinoColors.white;

  static Color get fill => dark
      ? const Color(0x1FFFFFFF)
      : CupertinoColors.tertiarySystemFill;

  static CupertinoThemeData theme() => CupertinoThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: pageBottom,
        primaryColor: CupertinoColors.systemBlue,
        barBackgroundColor: dark
            ? const Color(0xCC16161C)
            : const Color(0xCCFBFBFD),
        textTheme: const CupertinoTextThemeData(
          textStyle: TextStyle(
            fontFamily: 'Microsoft YaHei UI',
            fontSize: 14,
            color: CupertinoColors.label,
          ),
        ),
      );
}

class Luac2cApp extends StatelessWidget {
  const Luac2cApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeCtl.I,
      builder: (context, _) => CupertinoApp(
        title: 'luac2c 客户端',
        debugShowCheckedModeBanner: false,
        theme: Glass.theme(),
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
/// Liquid Glass 卡片：背景高斯模糊 + 半透明填充 + 顶部高光 + 边缘高光描边
class IosCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const IosCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14)});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(14);
    return DecoratedBox(
      // 阴影画在最外层（BackdropFilter 会裁掉后面的阴影）
      decoration: BoxDecoration(borderRadius: r, boxShadow: Glass.cardShadow),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: double.infinity,
            // 垂直渐变：顶部高光 -> 主体填充，模拟玻璃受光面
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Glass.cardGloss, Glass.cardFill, Glass.cardFill],
                stops: const [0, 0.35, 1],
              ),
              borderRadius: r,
              // 内发光式边缘高光：液态玻璃的折射轮廓
              border: Border.all(color: Glass.cardEdge, width: 0.8),
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 卡片内小标题
class SectionTitle extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 15, color: CupertinoColors.systemGrey),
        const SizedBox(width: 6),
      ],
      Text(text,
          style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.systemGrey,
              letterSpacing: 0.2)),
      const Spacer(),
      ?trailing,
    ]);
  }
}

/// 工具状态指示灯
class StatusDot extends StatelessWidget {
  final bool ok;
  final String label;
  final String path;
  const StatusDot(
      {super.key, required this.ok, required this.label, required this.path});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: path,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: (ok ? CupertinoColors.systemGreen : CupertinoColors.systemRed)
              .withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
                color:
                    ok ? CupertinoColors.systemGreen : CupertinoColors.systemRed,
                shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: ok
                      ? CupertinoColors.systemGreen
                      : CupertinoColors.systemRed)),
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
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    // 液态玻璃需要"透"出东西：渐变底 + 色斑作为折射源，卡片再 BackdropFilter 模糊它
    return Stack(children: [
      Positioned.fill(child: ColoredBox(color: Glass.pageBottom, child: _glassBackdrop())),
      CupertinoPageScaffold(
        backgroundColor: CupertinoColors.transparent,
        navigationBar: CupertinoNavigationBar(
          middle: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: CupertinoColors.systemBlue,
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: const Icon(CupertinoIcons.chevron_left_slash_chevron_right,
                  size: 13, color: CupertinoColors.white),
            ),
            const SizedBox(width: 8),
            const Text('luac2c 客户端',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 30),
              onPressed: () => ThemeCtl.I.toggle(),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (c, a) =>
                    FadeTransition(opacity: a, child: c),
                child: Icon(
                  key: ValueKey<bool>(ThemeCtl.I.dark),
                  ThemeCtl.I.dark
                      ? CupertinoIcons.sun_max_fill
                      : CupertinoIcons.moon_fill,
                  size: 20,
                  color: ThemeCtl.I.dark
                      ? CupertinoColors.systemYellow
                      : CupertinoColors.systemIndigo,
                ),
              ),
            ),
            const SizedBox(width: 4),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 30),
              onPressed: _showAbout,
              child: const Icon(CupertinoIcons.info_circle, size: 21),
            ),
          ]),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sourceCard(),
                const SizedBox(height: 12),
                _modeCard(),
                const SizedBox(height: 12),
                _toolsCard(),
                const SizedBox(height: 12),
                _actionsCard(),
                const SizedBox(height: 10),
                _statusBar(),
                const SizedBox(height: 10),
                Expanded(child: _logCard()),
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  /// 玻璃背后的"折射源"：对角渐变 + 三团柔和色斑
  Widget _glassBackdrop() {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Glass.pageTop, Glass.pageBottom],
          ),
        ),
        child: Stack(children: [
          Positioned(
            top: -110,
            left: -70,
            child: _blob(320, Glass.blob1),
          ),
          Positioned(
            top: 180,
            right: -90,
            child: _blob(360, Glass.blob2),
          ),
          Positioned(
            bottom: -120,
            left: 60,
            child: _blob(300, Glass.blob3),
          ),
        ]),
      ),
    );
  }

  /// 单个径向渐变模糊色斑
  Widget _blob(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [
          color,
          color.withValues(alpha: 0.0),
        ]),
      ),
    );
  }

  // ---- 源文件（批量列表） ----
  Widget _sourceCard() {
    final hasFiles = _files.isNotEmpty;
    return IosCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            hasFiles ? '源文件（${_files.length} 个）' : '源文件',
            icon: CupertinoIcons.doc_text,
            trailing: hasFiles
                ? CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 22),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _files.clear();
                              _results.clear();
                              _doneCount = 0;
                              _totalCount = 0;
                            }),
                    child: const Text('全部移除',
                        style: TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.systemRed)),
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
                      color: Glass.fill,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Text('点击「添加文件」多选，或把多个 .lua 文件拖进窗口',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: CupertinoColors.placeholderText)),
                  ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  borderRadius: BorderRadius.circular(9),
                  color: Glass.fill,
                  onPressed: _busy ? null : pickFile,
                  child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(CupertinoIcons.plus_circle,
                            size: 14, color: CupertinoColors.activeBlue),
                        SizedBox(width: 6),
                        Text('添加文件（可多选）',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: CupertinoColors.activeBlue)),
                      ]),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 36,
              child: CupertinoButton.filled(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                borderRadius: BorderRadius.circular(9),
                onPressed: _busy ? null : () => _addFiles(_sampleFiles()),
                child: const Text('加入示例', style: TextStyle(fontSize: 12.5)),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 36,
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                borderRadius: BorderRadius.circular(9),
                color: Glass.fill,
                onPressed: openOutDir,
                child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.folder_open,
                          size: 14, color: CupertinoColors.activeBlue),
                      SizedBox(width: 6),
                      Text('目录',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: CupertinoColors.activeBlue)),
                    ]),
              ),
            ),
          ]),
        ],
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
    return Container(
      decoration: BoxDecoration(
        color: Glass.fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: _files.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, thickness: 0.5),
        itemBuilder: (context, i) {
          final p = _files[i];
          final name = p.split(r'\').last;
          final res = _results[p];
          return Row(children: [
            Icon(
                res == null
                    ? CupertinoIcons.doc_text
                    : res
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.xmark_circle_fill,
                size: 14,
                color: res == null
                    ? CupertinoColors.systemGrey
                    : res
                        ? CupertinoColors.systemGreen
                        : CupertinoColors.systemRed),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5)),
            ),
            Expanded(
              flex: 2,
              child: Text(p.substring(0, p.lastIndexOf(r'\')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10.5, color: CupertinoColors.systemGrey)),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 22),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _files.removeAt(i);
                        _results.remove(p);
                      }),
              child: const Icon(CupertinoIcons.xmark,
                  size: 13, color: CupertinoColors.systemGrey),
            ),
          ]);
        },
      ),
    );
  }

  // ---- 翻译模式与选项 ----
  Widget _modeCard() {
    return IosCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('翻译模式',
              icon: CupertinoIcons.slider_horizontal_3),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: CupertinoSlidingSegmentedControl<int>(
                groupValue: _mode,
                thumbColor: Glass.segThumb,
                children: const {
                  0: _SegText('默认多样化'),
                  1: _SegText('指定种子'),
                  2: _SegText('--static'),
                },
                onValueChanged: (v) {
                  if (v != null && !_busy) setState(() => _mode = v);
                },
              ),
            ),
            const SizedBox(width: 10),
            Opacity(
              opacity: _mode == 1 ? 1 : 0.45,
              child: SizedBox(
                width: 78,
                height: 32,
                child: CupertinoTextField(
                  controller: _seed,
                  enabled: !_busy && _mode == 1,
                  placeholder: 'seed',
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 12.5),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: Glass.fill,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          const Divider(height: 22, thickness: 0.5),
          _switchRow(
            icon: CupertinoIcons.cube,
            title: '--no-pool',
            subtitle: '关闭常量池，字面量直接进源码，便于调试',
            value: _nopool,
            onChanged: (v) => _nopool = v,
          ),
          const SizedBox(height: 4),
          _switchRow(
            icon: CupertinoIcons.text_alignleft,
            title: '--annotate',
            subtitle: '在生成的 C 代码中保留 opcode 注释',
            value: _annot,
            onChanged: (v) => _annot = v,
          ),
        ],
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
    return Row(children: [
      Icon(icon, size: 16, color: CupertinoColors.systemGrey),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w500)),
            const SizedBox(height: 1),
            Text(subtitle,
                style: const TextStyle(
                    fontSize: 11, color: CupertinoColors.systemGrey)),
          ],
        ),
      ),
      CupertinoSwitch(
        value: value,
        activeTrackColor: CupertinoColors.systemGreen,
        onChanged: _busy ? null : (x) => setState(() => onChanged(x)),
      ),
    ]);
  }

  // ---- 工具链 ----
  Widget _toolsCard() {
    return IosCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            '工具链',
            icon: CupertinoIcons.wrench,
            trailing: _tools.allOk
                ? const StatusDot(ok: true, label: '就绪', path: '全部工具已找到')
                : const StatusDot(ok: false, label: '有缺失', path: '见下方指示灯'),
          ),
          const SizedBox(height: 9),
          Wrap(spacing: 8, runSpacing: 8, children: [
            StatusDot(ok: _tools.luacOk, label: 'luac', path: _tools.luac),
            StatusDot(ok: _tools.l2cOk, label: 'luac2c', path: _tools.l2c),
            StatusDot(ok: _tools.luaOk, label: 'lua', path: _tools.lua),
            StatusDot(ok: _tools.gccOk, label: 'gcc', path: _tools.gcc),
          ]),
          const SizedBox(height: 9),
          Text(_tools.root,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11,
                  color: CupertinoColors.systemGrey,
                  fontFamily: 'Consolas')),
        ],
      ),
    );
  }

  // ---- 操作按钮 ----
  Widget _actionsCard() {
    return IosCard(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        SizedBox(
          width: double.infinity,
          height: 42,
          child: CupertinoButton.filled(
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(10),
            onPressed: _busy ? null : () => runPipeline(full: true),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (_busy)
                const CupertinoActivityIndicator(
                    radius: 8, color: CupertinoColors.white)
              else
                const Icon(CupertinoIcons.play_arrow_solid, size: 15),
              const SizedBox(width: 8),
              const Text('一键流水线',
                  style:
                      TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              Text('（翻译 → 编译 → 运行 → 比对）',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: CupertinoColors.white.withValues(alpha: 0.75))),
            ]),
          ),
        ),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(
              child: _minorButton(CupertinoIcons.doc_plaintext, '仅翻译 C',
                  () => runPipeline(full: false))),
          const SizedBox(width: 9),
          Expanded(
              child: _minorButton(CupertinoIcons.arrow_2_circlepath,
                  '重建 luac2c', rebuildLuac2c)),
          const SizedBox(width: 9),
          Expanded(
              child: _minorButton(
                  CupertinoIcons.folder_open, '输出目录', openOutDir)),
        ]),
      ]),
    );
  }

  Widget _minorButton(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      height: 36,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        borderRadius: BorderRadius.circular(9),
        color: Glass.fill,
        onPressed: _busy ? null : onTap,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 14, color: CupertinoColors.activeBlue),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, color: CupertinoColors.activeBlue)),
          ),
        ]),
      ),
    );
  }

  // ---- 状态条 ----
  Widget _statusBar() {
    final ok = _status.startsWith('通过') ||
        _status.startsWith('翻译完成') ||
        _status.contains('已重建') ||
        _status.contains('已复制');
    final bad = _status.startsWith('失败') || _status.startsWith('不一致');
    final color = bad
        ? CupertinoColors.systemRed
        : ok
            ? CupertinoColors.systemGreen
            : CupertinoColors.systemGrey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(children: [
        Icon(
            bad
                ? CupertinoIcons.xmark_circle_fill
                : ok
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.info_circle,
            size: 15,
            color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
        ),
        if (_busy)
          const CupertinoActivityIndicator(radius: 7)
        else if (_logLines.isNotEmpty)
          Text('${_logLines.length} 行',
              style: const TextStyle(
                  fontSize: 11, color: CupertinoColors.systemGrey)),
      ]),
    );
  }

  // ---- 日志 ----
  Widget _logCard() {
    final logFg = Glass.logFg;
    return Container(
      decoration: BoxDecoration(
        color: Glass.logBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Glass.logBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
            child: Row(children: [
              Icon(CupertinoIcons.doc_richtext, size: 13, color: logFg),
              const SizedBox(width: 7),
              Text('输出日志',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: logFg)),
              const Spacer(),
              CupertinoButton(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: copyLog,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.doc_on_doc, size: 12, color: logFg),
                  const SizedBox(width: 4),
                  Text('复制', style: TextStyle(fontSize: 11.5, color: logFg)),
                ]),
              ),
              CupertinoButton(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: () => setState(_logLines.clear),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.trash, size: 12, color: logFg),
                  const SizedBox(width: 4),
                  Text('清空', style: TextStyle(fontSize: 11.5, color: logFg)),
                ]),
              ),
            ]),
          ),
          Divider(height: 1, thickness: 1, color: Glass.logBorder),
          Expanded(
            child: CupertinoScrollbar(
              controller: _logScroll,
              child: SingleChildScrollView(
                controller: _logScroll,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _logLines.isEmpty ? '（暂无输出）' : _logLines.join('\n'),
                  style: TextStyle(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: ['Microsoft YaHei UI'],
                      fontSize: 12,
                      height: 1.45,
                      color: logFg),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('luac2c 客户端'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('把 Lua 5.5 字节码翻译成调用 Lua C API 的 C 源码，'
                  '并一键编译、运行、与 lua.exe 逐字节比对。'),
              const SizedBox(height: 10),
              Text('根目录：${_tools.root}',
                  style: const TextStyle(fontSize: 12)),
              Text('luac：${_tools.luac}',
                  style: const TextStyle(fontSize: 12)),
              Text('luac2c：${_tools.l2c}',
                  style: const TextStyle(fontSize: 12)),
              Text('lua：${_tools.lua}', style: const TextStyle(fontSize: 12)),
              Text('gcc：${_tools.gcc}', style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
              child: const Text('好'),
              onPressed: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
  }
}

class _SegText extends StatelessWidget {
  final String text;
  const _SegText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text, style: const TextStyle(fontSize: 12.5)),
    );
  }
}
