// 工具链探测：luac / luac2c / lua / gcc 以及 Lua 头文件与静态库。
//
// 设计约束：**本文件不得出现任何本机路径**。所有位置只能来自
// 环境变量、ini 配置、自动探测或系统 PATH，保证仓库在任意机器上都能构建。
import 'dart:io';

class Tools {
  String luac = '', l2c = '', lua = '', gcc = '';
  String inc1 = '', inc2 = '', lib = '';
  String root = '';

  /// 存在性在 [findTools] 里一次性算好。
  /// 用 getter 现算的话，界面每重建一次就要打 4 次磁盘 —— 批量处理时
  /// 每完成一个文件都重建一次，磁盘 IO 会明显拖慢 UI。
  bool luacOk = false, l2cOk = false, luaOk = false, gccOk = false;
  bool get allOk => luacOk && l2cOk && luaOk && gccOk;

  /// 状态签名：轮询时用它判断工具链是否真的变了，避免无谓的重建
  String get signature {
    String e(bool ok) => ok ? '1' : '0';
    return '$root|$luac${e(luacOk)}|$l2c${e(l2cOk)}|$lua${e(luaOk)}|$gcc${e(gccOk)}';
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

/// 读取 luac2c_gui.ini 的 [paths] 段（本机配置，不入库）。返回小写 key -> 值。
Map<String, String> _readPathsIni(String file) {
  final map = <String, String>{};
  final ini = File(file);
  if (!ini.existsSync()) return map;
  var inPaths = false;
  for (final raw in ini.readAsLinesSync()) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      inPaths = line.substring(1, line.length - 1).toLowerCase() == 'paths';
      continue;
    }
    if (!inPaths) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final v = line.substring(eq + 1).trim();
    if (v.isEmpty) continue;
    map[line.substring(0, eq).trim().toLowerCase()] = v.replaceAll('/', r'\');
  }
  return map;
}

/// 从 [start] 逐级向上返回最多 [n] 级父目录
List<String> _upwards(String start, int n) {
  final out = <String>[];
  var cur = start;
  for (var i = 0; i < n; i++) {
    final p = Directory(cur).parent.path;
    if (p.isEmpty || p == cur) break;
    cur = p;
    out.add(cur);
  }
  return out;
}

/// 探测工程根目录：含 luac2c.c 与 lua-5.5.1\src 的那一层。
/// 候选：程序所在目录 -> 逐级向上 -> 当前工作目录 -> 逐级向上。
String? _detectRoot(String start) {
  final seeds = <String>[
    start,
    ..._upwards(start, 5),
    Directory.current.path,
    ..._upwards(Directory.current.path, 5),
  ];
  for (final d in seeds) {
    if (File('$d\\luac2c.c').existsSync() &&
        Directory('$d\\lua-5.5.1\\src').existsSync()) {
      return d;
    }
  }
  for (final d in seeds) {
    if (Directory('$d\\lua-5.5.1\\src').existsSync() ||
        File('$d\\luac.exe').existsSync()) {
      return d;
    }
  }
  return null;
}

/// MinGW / MSYS2 / TDM 等常见安装位置。
/// 只由系统盘与 ProgramFiles 推导，不含任何个人目录。
List<String> _gccConventions() {
  final env = Platform.environment;
  final drive = env['SystemDrive'] ?? r'C:';
  final pf = env['ProgramFiles'] ?? '$drive\\Program Files';
  final dirs = <String>[
    '$drive\\mingw64\\bin',
    '$drive\\msys64\\mingw64\\bin',
    '$drive\\msys64\\usr\\bin',
    '$drive\\TDM-GCC-64\\bin',
    '$drive\\MinGW\\bin',
    '$drive\\Strawberry\\c\\bin',
    '$pf\\mingw64\\bin',
    '$pf\\LLVM\\bin',
  ];
  for (final k in ['MINGW_HOME', 'MINGW64_HOME', 'MSYSTEM_PREFIX', 'MSYS2_ROOT']) {
    final v = env[k];
    if (v != null && v.isNotEmpty) {
      dirs.add('$v\\bin');
      dirs.add(v);
    }
  }
  return dirs.map((d) => '$d\\gcc.exe').toList();
}

/// 兜底扫描的缓存：工具链每 5s 轮询一次，不能每次都扫盘
List<String>? _gccScanCache;

/// 最后手段：在少数根目录里做有预算的两层浅扫找 gcc.exe。
/// 命中即返回、总量封顶，不会遍历整个磁盘。
List<String> _scanForGcc() {
  final cached = _gccScanCache;
  if (cached != null) return cached;
  final env = Platform.environment;
  final drive = env['SystemDrive'] ?? r'C:';
  final roots = <String>[
    '$drive\\',
    if (env['ProgramFiles'] != null) env['ProgramFiles']!,
    if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Programs',
  ];
  var budget = 3000;
  for (final root in roots) {
    if (budget <= 0) break;
    List<FileSystemEntity> l1;
    try {
      l1 = Directory(root).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e1 in l1) {
      if (budget <= 0) break;
      if (e1 is! Directory) continue;
      budget--;
      final p1 = e1.path;
      for (final c in ['$p1\\gcc.exe', '$p1\\bin\\gcc.exe']) {
        if (File(c).existsSync()) return _gccScanCache = <String>[c];
      }
      List<FileSystemEntity> l2;
      try {
        l2 = Directory(p1).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e2 in l2) {
        if (budget <= 0) break;
        if (e2 is! Directory) continue;
        budget--;
        final c = '${e2.path}\\bin\\gcc.exe';
        if (File(c).existsSync()) return _gccScanCache = <String>[c];
      }
    }
  }
  return _gccScanCache = const <String>[];
}

/// 工具链探测。**代码里不写任何本机路径**，顺序为：
///   1. 环境变量：LUAC2C_ROOT / LUAC / LUAC2C / LUA / GCC（GCC 也可写 CC）
///   2. 程序目录下的 luac2c_gui.ini 的 [paths] 段
///   3. 工程根目录（自动探测，或由 LUAC2C_ROOT 指定）
///   4. 程序所在目录
///   5. 系统 PATH
///   6. 常见安装位置（仅 gcc），最后是有预算的浅层扫描
Tools findTools() {
  final t = Tools();
  final env = Platform.environment;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final ini = _readPathsIni('$exeDir\\luac2c_gui.ini');

  String? envOf(Iterable<String> keys) {
    for (final k in keys) {
      final v = env[k];
      if (v != null && v.trim().isNotEmpty) {
        return v.trim().replaceAll('/', r'\');
      }
    }
    return null;
  }

  t.root =
      envOf(['LUAC2C_ROOT']) ?? ini['root'] ?? _detectRoot(exeDir) ?? exeDir;

  String? firstExisting(Iterable<String> paths) {
    for (final p in paths) {
      if (p.isEmpty) continue;
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  String resolve(String name, Iterable<String> envKeys) {
    var hit = firstExisting(<String>[
      envOf(envKeys) ?? '',
      ini[name.toLowerCase()] ?? '',
      '${t.root}\\$name.exe',
      '$exeDir\\$name.exe',
    ]);
    hit ??= firstExisting(_fromPathEnv(name));
    if (hit == null && name == 'gcc') {
      hit = firstExisting(_gccConventions()) ?? firstExisting(_scanForGcc());
    }
    return hit ?? '${t.root}\\$name.exe'; // 兜底，运行时报错可见
  }

  t.luac = resolve('luac', ['LUAC']);
  t.l2c = resolve('luac2c', ['LUAC2C', 'L2C']);
  t.lua = resolve('lua', ['LUA']);
  t.gcc = resolve('gcc', ['GCC', 'CC']);
  // 存在性只在这里探测一次，之后纯内存读取
  t.luacOk = File(t.luac).existsSync();
  t.l2cOk = File(t.l2c).existsSync();
  t.luaOk = File(t.lua).existsSync();
  t.gccOk = File(t.gcc).existsSync();
  t.inc1 = ini['inc1'] ?? '${t.root}\\lua-5.5.1\\src';
  t.inc2 = ini['inc2'] ?? '${t.root}\\lua5.5-include';
  t.lib = ini['lib'] ?? '${t.root}\\lua-5.5.1\\build\\liblua.a';
  return t;
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
