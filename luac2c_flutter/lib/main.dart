// luac2c 客户端 (Flutter Windows Desktop, Material You / Material Design 3)
//
// 与 Win32 原生版 luac2c_gui.c 功能一致：
//   完整流程: 编译字节码 -> 转译为 C -> gcc 编译 -> 运行 -> 与 lua.exe 输出比对
//   仅生成 C 源码 / 重新编译 luac2c.exe / 三种代码布局 + 常量池、注释等输出选项
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

import 'account.dart';
import 'mine_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeCtl.I.load();
  await AccountCtl.I.load();   // 恢复"记住我"的会话
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
        title: 'luac2c For Windows',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Brightness.light, ThemeCtl.I.seed),
        darkTheme: AppTheme.build(Brightness.dark, ThemeCtl.I.seed),
        themeMode: ThemeCtl.I.dark ? ThemeMode.dark : ThemeMode.light,
        home: const AppShell(),
      ),
    );
  }
}

// ---------------------------------------------------------------- 外壳
/// 底部导航栏（M3 NavigationBar）在两个界面之间切换：
/// 「防护」是构建与加固的主界面，「我的」是账号与用户指纹。
/// 每个界面自己不带 AppBar，标题栏由外壳统一提供。
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
          const Text('luac2c 客户端'),
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
            onPressed: () => _showAbout(context),
          ),
          const SizedBox(width: 6),
        ],
      ),
      // IndexedStack 保留两个界面的状态：切走再切回来，日志和列表都还在。
      body: IndexedStack(
        index: _index,
        children: const [HomePage(), MinePage(),],
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

void _showAbout(BuildContext context) {
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

  /// 状态签名：轮询时用它判断工具链是否真的变了，避免无谓的 setState
  String get signature {
    String e(String p) => File(p).existsSync() ? '1' : '0';
    return '$root|$luac${e(luac)}|$l2c${e(l2c)}|$lua${e(lua)}|$gcc${e(gcc)}';
  }

  /// 缺失的工具名列表（用于一次性提示，而不是跑到一半才报错）
  /// 给的是"干什么用的 + 可执行文件名"，而不是裸的 luac / luac2c
  List<String> missing({required bool full}) => <String>[
        if (!luacOk) 'luac luac.exe',
        if (!l2cOk) '主程序 luac2c.exe',
        if (full && !gccOk) 'C 编译器 gcc.exe',
        if (full && !luaOk) 'lua lua.exe',
      ];
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
/// 子进程执行结果：退出码 + 输出 + 耗时 + 是否超时
class StepResult {
  final int exitCode;
  final String output;
  final int ms;
  final bool timeout;
  StepResult(this.exitCode, this.output, {this.ms = 0, this.timeout = false});
}

/// 子进程默认超时（防止某个环节卡死导致整条流水线永挂）
const Duration kStepTimeout = Duration(seconds: 60);

/// 单条命令最多收集的输出行数（防止日志爆炸拖垮 UI 与内存）
const int kMaxOutputLines = 400;

/// 当前存活的子进程（供"停止"时立即终止，而不是等步骤跑完）
final List<Process> _activeProcs = <Process>[];

/// 终止所有在跑的子进程
void killActiveProcesses() {
  for (final p in List<Process>.of(_activeProcs)) {
    try {
      p.kill();
    } catch (_) {/* 已退出 */}
  }
  _activeProcs.clear();
}

/// 启动子进程并收集输出。
/// 健壮性要点：
///   1. 超时后 kill 进程，不再无限等待；
///   2. 输出解码允许非法 UTF-8（中文 Windows 下 gcc/lua 的报错常是 GBK）；
///   3. 输出行数截断，避免超大输出撑爆内存与日志控件；
///   4. 记录耗时，便于定位慢步骤；
///   5. 支持取消（[isCancelled]）。
Future<StepResult> runCapture(String exe, List<String> args, String? cwd,
    {Duration timeout = kStepTimeout, bool Function()? isCancelled}) async {
  final sw = Stopwatch()..start();
  if (isCancelled?.call() ?? false) {
    return StepResult(-2, '已取消', ms: 0);
  }
  Process? p;
  final subs = <StreamSubscription>[];
  try {
    p = await Process.start(exe, args,
        workingDirectory: cwd, runInShell: false);
    _activeProcs.add(p);
    final out = <String>[];
    var lines = 0;
    var truncated = false;

    void attach(Stream<List<int>> s) {
      subs.add(s
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) {
        if (lines >= kMaxOutputLines) {
          truncated = true;
          return;
        }
        lines++;
        out.add(l);
      }, onError: (_) {/* 解码异常不应中断流程 */}));
    }

    attach(p.stdout);
    attach(p.stderr);

    final streamsDone = Future.wait(subs.map((s) => s.asFuture()));
    var timedOut = false;
    try {
      await Future.wait<Object?>([p.exitCode, streamsDone]).timeout(timeout,
          onTimeout: () {
        timedOut = true;
        return <Object?>[];
      });
    } catch (_) {/* 子进程异常关闭等，不应中断流水线 */}

    if (timedOut) {
      p.kill(ProcessSignal.sigterm);
      for (final s in subs) {
        unawaited(s.cancel());
      }
      return StepResult(-3, '执行超时（${timeout.inSeconds}s），已终止进程',
          ms: sw.elapsedMilliseconds, timeout: true);
    }

    final code = await p.exitCode;
    if (truncated) {
      out.add('… （输出已截断，仅保留前 $kMaxOutputLines 行）');
    }
    return StepResult(code, out.join('\n'), ms: sw.elapsedMilliseconds);
  } catch (e) {
    return StepResult(-1, e.toString(), ms: sw.elapsedMilliseconds);
  } finally {
    if (p != null) {
      _activeProcs.remove(p);
      // 进程已结束但流未收干净时，确保订阅被释放
      for (final s in subs) {
        unawaited(s.cancel());
      }
    }
  }
}

/// 单个文件的处理结果：是否通过 + 该文件产生的日志 + 耗时。
/// 日志先攒在局部缓冲里，文件跑完再一次性入库，
/// 这样并发处理多个文件时日志不会互相穿插。
class FileOutcome {
  final String path;
  final bool ok;
  final List<String> lines;
  final int ms;
  final bool cancelled;
  FileOutcome(this.path, this.ok, this.lines,
      {this.ms = 0, this.cancelled = false});
}

/// 换行统一为 LF，避免 CRLF 差异造成误判
String _normalize(String s) =>
    trimTail(s.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));

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
/// 日志存储器：独立可监听容器 + 节流批量刷新。
/// 配合 ListenableBuilder 使用，日志刷新只重建日志面板本身，
/// 不会连带重建文件列表/工具链卡片/按钮区（批量跑几十个文件时体感差别很大）。
class LogStore extends ChangeNotifier {
  final List<String> lines = <String>[];
  final List<String> _buf = <String>[];
  Timer? _timer;
  static const int maxLines = 4000;

  void add(String s) {
    _buf.add(s);
    if (_buf.length >= 200) {
      flush();
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 80), flush);
  }

  void addAll(Iterable<String> it) {
    _buf.addAll(it);
    if (_buf.length >= 200) {
      flush();
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 80), flush);
  }

  /// 把缓冲里的行一次性合入（节流刷新点）
  void flush() {
    _timer = null;
    if (_buf.isEmpty) return;
    lines.addAll(_buf);
    _buf.clear();
    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
      lines.insert(0, '… （更早的日志已自动销毁，仅保留最近 $maxLines 行）');
    }
    notifyListeners();
  }

  void clear() {
    _buf.clear();
    lines.clear();
    notifyListeners();
  }

  /// 释放定时器（注意：不能叫 dispose，会与 ChangeNotifier.dispose 冲突）
  void close() {
    _timer?.cancel();
    _timer = null;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _seed = TextEditingController(text: '0');
  final ScrollController _logScroll = ScrollController();
  final LogStore _log = LogStore();
  // 日志是否自动跟随底部（用户往上翻看历史时暂停跟随）
  bool _stickBottom = true;
  // 批量处理：待处理文件列表 + 每个文件的结果
  final List<String> _files = <String>[];
  final Map<String, bool> _results = <String, bool>{};
  int _doneCount = 0, _totalCount = 0;
  Tools _tools = Tools();
  // 代码布局：0 随机（每次不同） 1 固定种子（可复现） 2 不混淆（原始直译）
  int _mode = 0;
  bool _nopool = false, _annot = false, _busy = false;
  // 运行时防护：反调试 + 代码/常量完整性自校验（关闭等价于 --no-guard）
  bool _guard = true;
  // 取消标志：用户点"停止"后，流水线在下一个步骤边界退出
  bool _cancel = false;
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
    // 用户往上翻时停止自动跟随底部，回到底部后恢复（纯字段赋值，不触发重建）
    _logScroll.addListener(() {
      if (!_logScroll.hasClients) return;
      _stickBottom = _logScroll.position.extentAfter < 24;
    });
    // 工具链探测：轮询会遍历 PATH 做 existsSync，因此
    // ① 间隔放宽到 5s；② 流水线运行期间跳过（此时工具不会变，且别抢 IO）
    _toolsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_busy || !mounted) return;
      final t = findTools();
      if (t.signature != _tools.signature) {
        setState(() => _tools = t);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() => _tools = findTools());
      log('配置文件遍历完成。选择 .lua 文件，或直接把文件拖进窗口。');
    });
  }

  @override
  void dispose() {
    _toolsTimer?.cancel();
    _log.flush();
    _log.close();
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

  /// 写日志。高频调用走缓冲 + 80ms 节流，且只刷新日志面板自身。
  void log(String s) => _log.add(s);

  /// 立即把缓冲落盘（流水线结束/停止时调用，保证日志不丢）
  void _flushLog() => _log.flush();

  void setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  /// 多选文件（Windows 文件对话框，Multiselect）
  Future<void> pickFile() async {
    final r = await runCapture(
        'powershell.exe',
        [
          // -STA：WinForms 的 OpenFileDialog 要求单线程套间，否则可能直接抛异常
          '-NoProfile',
          '-STA',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms;'
              '\$f = New-Object System.Windows.Forms.OpenFileDialog;'
              '\$f.Multiselect = \$true;'
              '\$f.Filter = "Lua 源文件(*.lua;*.luac)|*.lua;*.luac|所有文件(*.*)|*.*";'
              'if (\$f.ShowDialog() -eq "OK") { \$f.FileNames | ForEach-Object { Write-Output \$_ } }'
        ],
        null,
        // 对话框要等人操作，超时必须放宽，否则默认 60s 会把 powershell 杀掉
        timeout: const Duration(minutes: 10));
    final lines = r.output
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && File(e).existsSync())
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
    await Clipboard.setData(ClipboardData(text: _log.lines.join('\n')));
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
    if (!_guard) args.add('--no-guard');
    // 登录后把账号标识交给 luac2c：产物里会嵌入这个账号的指纹，
    // 之后拿 luac2c --who 就能从任意一份副本反查归属。
    final uid = AccountCtl.I.uid;
    if (uid != null && uid.isNotEmpty) args.addAll(['--fingerprint', uid]);
    return args;
  }

  // ---- 批量流水线 ----
  Future<void> runPipeline({required bool full}) async {
    if (_busy) return;
    if (_files.isEmpty) {
      await _msg('请先添加 .lua 文件（可多选，或把多个文件拖进窗口）');
      return;
    }
    // 前置校验：一次检查全部需要的工具，避免跑到一半才发现缺工具
    final t = findTools();
    if (t.signature != _tools.signature && mounted) setState(() => _tools = t);
    final missing = t.missing(full: full);
    if (missing.isNotEmpty) {
      await _msg('缺少工具：${missing.join('、')}（根目录：${_tools.root}，已尝试系统 PATH）');
      return;
    }
    // 剔除已失效的文件，避免列表里有被删除的路径
    final stale = _files.where((f) => !File(f).existsSync()).toList();
    if (stale.isNotEmpty) {
      _files.removeWhere((f) => stale.contains(f));
      log('! 已忽略 ${stale.length} 个不存在的文件');
    }
    if (_files.isEmpty) {
      await _msg('文件列表为空或文件均已不存在');
      return;
    }

    setState(() {
      _busy = true;
      _cancel = false;
      _results.clear();
      _totalCount = _files.length;
      _doneCount = 0;
    });
    final sw = Stopwatch()..start();
    var pass = 0;
    try {
      // 并发工作池：每个文件要串行跑 5 个子进程，但文件之间互不依赖，
      // 并行处理能把 luac/gcc 的等待时间重叠起来，批量场景提速明显。
      final queue = List<String>.from(_files);
      var cursor = 0;
      final workers = _workerCount < queue.length ? _workerCount : queue.length;
      log('▶ 开始处理 ${queue.length} 个文件（并发 $workers，'
          '${Platform.numberOfProcessors} 核）');

      Future<void> worker() async {
        while (!_cancel) {
          if (cursor >= queue.length) return;
          // Dart 单线程事件循环：读与自增之间没有 await，并发安全
          final f = queue[cursor++];
          final o = await _processOne(f, full);
          _log.addAll(o.lines); // 整段入库，避免逐行触发刷新
          if (o.ok) pass++;
          if (!mounted) return;
          setState(() {
            _doneCount++;
            _results[f] = o.ok;
          });
          setStatus('进度 $_doneCount/$_totalCount —— 已通过 $pass');
        }
      }

      await Future.wait(List.generate(workers, (_) => worker()));
      if (_cancel) log('■ 已停止，剩余任务未执行');
    } catch (e) {
      log('! 流程异常：$e');
      setStatus('流程异常：$e');
    } finally {
      _flushLog();
      if (mounted) setState(() => _busy = false);
    }
    sw.stop();
    final done = _doneCount;
    final failed = done - pass;
    final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
    if (_cancel) {
      setStatus('已停止：完成 $done/$_totalCount，通过 $pass');
      log('■ 已停止（耗时 ${secs}s）');
    } else if (failed == 0) {
      setStatus('批量通过：$pass/$done（${secs}s）');
      log('✓ 批量全部通过（$pass/$done，耗时 ${secs}s）');
    } else {
      setStatus('批量完成：$pass 通过，$failed 失败（${secs}s）');
      log('✗ 批量结束：失败 $failed 个，通过 $pass 个（耗时 ${secs}s）');
    }
  }

  /// 流水线并发度：按 CPU 核数自适应，上限 6（再多只是抢 gcc 的 CPU）
  int get _workerCount {
    final w = Platform.numberOfProcessors ~/ 2;
    if (w < 1) return 1;
    if (w > 6) return 6;
    return w;
  }

  /// 请求停止：立刻终止当前所有子进程，并在下一个步骤边界退出
  void stopPipeline() {
    if (!_busy) return;
    _cancel = true;
    killActiveProcesses(); // 立刻终止正在跑的子进程，不等它们自然结束
    setStatus('正在停止…');
    log('! 收到停止请求，已终止子进程');
    _flushLog();
  }

  /// 处理单个文件。日志先进局部缓冲，返回后由调用方统一入库。
  Future<FileOutcome> _processOne(String srcPath, bool full) async {
    final out = <String>[];
    void p(String s) => out.add(s);
    void pOut(StepResult r) {
      if (r.output.trim().isNotEmpty) {
        p('      ${r.output.trim().replaceAll('\n', '\n      ')}');
      }
    }

    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    p('');
    p('──── ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $srcPath');
    final sep = Platform.isWindows ? r'\' : '/';
    final dir = srcPath.contains(sep)
        ? srcPath.substring(0, srcPath.lastIndexOf(sep))
        : Directory.current.path;
    final base = srcPath.split(sep).last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final pLuac = '$dir$sep$stem.luac';
    final pC = '$dir$sep${stem}_out.c';
    final pExe = '$dir$sep${stem}_out.exe';

    // 清理上一轮的中间产物：避免用陈旧结果"假通过"
    for (final path in <String>[pLuac, pC, if (full) pExe]) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {/* 删不掉不影响后续，写入会覆盖 */}
    }

    final sw = Stopwatch()..start();
    var ok = false;
    try {
      p('[1/5] luac  编译字节码');
      if (_cancel) throw '已取消';
      var r = await runCapture(_tools.luac, ['-o', pLuac, srcPath], dir,
          timeout: const Duration(seconds: 30), isCancelled: () => _cancel);
      pOut(r);
      if (r.exitCode != 0) throw 'luac 退出码 ${r.exitCode}';
      if (!File(pLuac).existsSync()) throw 'luac 未生成 $pLuac';
      p('      → $pLuac  (${r.ms}ms)');

      p('[2/5] luac2c  翻译为 C');
      if (_cancel) throw '已取消';
      r = await runCapture(_tools.l2c, l2cArgs(pLuac, pC), dir,
          timeout: const Duration(seconds: 60), isCancelled: () => _cancel);
      pOut(r);
      if (r.exitCode != 0) throw 'luac2c 退出码 ${r.exitCode}';
      if (!File(pC).existsSync()) throw 'luac2c 未生成 $pC';
      p('      → $pC  (${r.ms}ms)');
      if (AccountCtl.I.loggedIn) {
        p('      ID ${AccountCtl.I.fingerprint}（账号 ${AccountCtl.I.name}）');
      }
      if (!full) {
        p('✓ C 源码已生成 → $pC');
        ok = true;
        return FileOutcome(srcPath, true, out, ms: sw.elapsedMilliseconds);
      }

      p('[3/5] gcc  编译链接');
      if (_cancel) throw '已取消';
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
            // -pipe：用管道代替临时文件，减少磁盘 IO
            if (Platform.isWindows) '-pipe',
            '-o',
            pExe,
            _tools.lib,
            '-lm'
          ],
          dir,
          timeout: const Duration(seconds: 180),
          isCancelled: () => _cancel);
      pOut(r);
      if (r.exitCode != 0) throw 'gcc 退出码 ${r.exitCode}';
      if (!File(pExe).existsSync()) throw 'gcc 未生成 $pExe';
      p('      → $pExe  (${r.ms}ms)');

      p('[4/5] 运行生成物');
      if (_cancel) throw '已取消';
      final gen = await runCapture(pExe, [], dir,
          timeout: const Duration(seconds: 30), isCancelled: () => _cancel);
      if (gen.timeout) throw '产物运行超时，已终止';

      p('[5/5] 与 lua.exe 输出比对');
      if (_cancel) throw '已取消';
      final ref = await runCapture(_tools.lua, [srcPath], dir,
          timeout: const Duration(seconds: 30), isCancelled: () => _cancel);
      if (ref.timeout) throw 'lua.exe 运行超时，已终止';
      // 规范化换行：Windows 下 CRLF/LF 差异不应判为失败
      final genOut = _normalize(gen.output);
      final refOut = _normalize(ref.output);
      if (genOut.isNotEmpty) {
        p('      生成物> ${genOut.replaceAll('\n', '\n      ')}');
      }
      if (refOut.isNotEmpty) {
        p('      lua.exe> ${refOut.replaceAll('\n', '\n      ')}');
      }
      final same = genOut == refOut && gen.exitCode == ref.exitCode;
      ok = same;
      if (same) {
        p('      ✓ 输出一致，退出码一致 (${gen.exitCode})');
        p('✓ 通过：$srcPath');
      } else {
        p('      ✗ 不一致（exit ${gen.exitCode} vs ${ref.exitCode}）');
        p('✗ 失败：$srcPath');
      }
    } catch (e) {
      p('      ✗ $e');
      p('✗ 失败：$srcPath');
      ok = false;
    }
    sw.stop();
    p('      [${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s]');
    return FileOutcome(srcPath, ok, out, ms: sw.elapsedMilliseconds);
  }

  Future<void> rebuildLuac2c() async {
    if (_busy) return;
    setState(() => _busy = true);
    log('');
    log('[重新编译] gcc luac2c.c -O2 -o luac2c.exe');
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
        log('      ✓ luac2c.exe 已重新编译');
        setStatus('luac2c.exe 已重新编译');
      } else {
        log('      ✗ gcc 退出码 ${r.exitCode}');
        setStatus('重新编译失败');
      }
    } catch (e) {
      log('      ✗ $e');
      setStatus('重新编译失败');
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
    // 左右双栏：左栏操作区可滚动，右栏是整屏高度的运行日志。
    // 原先所有卡片排在一列里，固定高度的部分把窗口占满之后，日志那个
    // Expanded 只剩 0 高度 —— 这就是"终端显示不出来"的原因。
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
                  child: SingleChildScrollView(
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
                const SizedBox(width: 12),
                Expanded(child: _logCard()),
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
              label: const Text('加入示例脚本'),
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
            Text(_modeHint,
                style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            const Divider(height: 22),
            _switchRow(
              icon: Icons.security_outlined,
              title: '运行时防护',
              subtitle: _mode == 2
                  ? '「不混淆」模式下 luac2c 不会启动防护'
                  : '注入反调试与完整性自校验，局部修改会产生静默错误',
              value: _guard && _mode != 2,
              enabled: _mode != 2,
              onChanged: (v) => _guard = v,
            ),
            const SizedBox(height: 4),
            _switchRow(
              icon: Icons.inventory_2_outlined,
              title: '关闭常量池',
              subtitle: '常量和字符将直接写进 C 源码',
              value: _nopool,
              onChanged: (v) => _nopool = v,
            ),
            const SizedBox(height: 4),
            _switchRow(
              icon: Icons.comment_outlined,
              title: '保留指令注释',
              subtitle: '在生成的 C 源码里逐条标注字节码指令',
              value: _annot,
              onChanged: (v) => _annot = v,
            ),
          ],
        ),
      ),
    );
  }

  /// 三种布局的一句话说明（免得「随机 / 固定种子 / 不混淆」看着没头没尾）
  String get _modeHint {
    switch (_mode) {
      case 1:
        return '默认：静态Seed不变';
      case 2:
        return '不混淆：不注入静态&动态防护功能';
      default:
        return '随机：每次转译更换随机Seed';
    }
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
                if (!_busy) setState(() => onChanged(x));
              }
            : null,
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
                  ? const StatusDot(ok: true, label: '就绪', path: '所有工具已找到')
                  : const StatusDot(
                      ok: false, label: '有缺失', path: '见下方指示灯'),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              StatusDot(
                  ok: _tools.luacOk,
                  label: '字节码编译器',
                  path: _tools.luac),
              StatusDot(ok: _tools.l2cOk, label: '主程序', path: _tools.l2c),
              StatusDot(ok: _tools.luaOk, label: 'lua', path: _tools.lua),
              StatusDot(ok: _tools.gccOk, label: 'C 编译器', path: _tools.gcc),
            ]),
            const SizedBox(height: 10),
            Text('根目录  ${_tools.root}',
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
      Row(children: [
        Expanded(
          child: Tooltip(
            message: '编译字节码 → 转译为 C → gcc 编译 → 运行生成物',
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
                child: Text('一键构建', style: TextStyle(fontSize: 15)),
              ),
            ),
          ),
        ),
        if (_busy) ...[
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: stopPipeline,
            icon: const Icon(Icons.stop, size: 18),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('停止', style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ]),
      if (_busy) ...[
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _totalCount == 0 ? null : _doneCount / _totalCount,
            minHeight: 6,
          ),
        ),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
            child: _minorButton(Icons.description_outlined, '仅生成 C 源码',
                () => runPipeline(full: false),
                tip: '仅生成 C 源码，不运行')),
        const SizedBox(width: 10),
        Expanded(
            child: _minorButton(
                Icons.build_outlined, '重新编译 luac2c', rebuildLuac2c,
                tip: '用 gcc 重新编译 luac2c.c，生成新的 luac2c.exe')),
        const SizedBox(width: 10),
        Expanded(
            child: _minorButton(Icons.folder_open_outlined, '打开输出目录',
                openOutDir,
                tip: '在资源管理器中打开源文件所在目录')),
      ]),
    ]);
  }

  Widget _minorButton(IconData icon, String label, VoidCallback onTap,
      {String? tip}) {
    final btn = OutlinedButton.icon(
      onPressed: _busy ? null : onTap,
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
    final ok = _status.startsWith('通过') ||
        _status.startsWith('批量通过') ||
        _status.contains('已重新编译') ||
        _status.contains('已复制');
    final bad = _status.startsWith('失败') ||
        _status.startsWith('不一致') ||
        _status.endsWith('失败');
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
          ),
      ]),
    );
  }

  // ---- 日志（M3：surface 容器 + 等宽字体） ----
  /// 只让日志区订阅 [LogStore]：日志刷新不再重建本页其它部分
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
              Text('运行日志',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const Spacer(),
              // 行数用 ListenableBuilder 单独订阅，避免整页随日志重建
              ListenableBuilder(
                listenable: _log,
                builder: (context, _) => Text('${_log.lines.length} 行',
                    style: TextStyle(
                        fontSize: 11.5, color: cs.onSurfaceVariant)),
              ),
              TextButton.icon(
                onPressed: copyLog,
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text('复制'),
              ),
              TextButton.icon(
                onPressed: _log.clear,
                icon: const Icon(Icons.delete_outline, size: 15),
                label: const Text('清空'),
              ),
            ]),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            child: ListenableBuilder(
              listenable: _log,
              builder: (context, _) {
                // 新日志到达后跟随到底部（用户上翻时由 _stickBottom 暂停）
                if (_stickBottom) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_logScroll.hasClients) {
                      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
                    }
                  });
                }
                return Scrollbar(
                  controller: _logScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _logScroll,
                    padding: const EdgeInsets.all(12),
                    child: RepaintBoundary(
                      child: SelectableText(
                        _log.lines.isEmpty ? '（暂无输出）' : _log.lines.join('\n'),
                        style: TextStyle(
                            fontFamily: 'Consolas',
                            fontFamilyFallback: const ['Microsoft YaHei UI'],
                            fontSize: 12,
                            height: 1.45,
                            color: cs.onSurface),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

}
