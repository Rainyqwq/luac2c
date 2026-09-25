// 单个源文件的构建步骤：编译字节码 → 转译为 C → gcc 编译 → 运行 → 与 lua.exe 比对。
//
// 从 pipeline.dart 里分出来的原因：调度（并发池、进度、状态）和"一个文件怎么跑完"
// 是两件事，混在一起会让两边都难读。这里只负责跑，不知道外面有几个文件在跑。
import 'dart:io';

import 'account.dart';
import 'runner.dart';
import 'tools.dart';

/// 代码布局：0 随机（每次不同） 1 固定种子（可复现） 2 不混淆（原始直译）
const int layoutRandom = 0;
const int layoutSeed = 1;
const int layoutPlain = 2;

/// 一次构建用的输出选项。
///
/// 从 PipelineCtl 里单独拎出来，是为了让「构建」这件事不依赖界面控制器：
/// 无界面测试、以后的命令行模式都能直接构造它。
class BuildOptions {
  final int mode;
  final String seed;
  final bool noPool;
  final bool annotate;
  final bool guard;
  const BuildOptions({
    this.mode = layoutRandom,
    this.seed = '0',
    this.noPool = false,
    this.annotate = false,
    this.guard = true,
  });

  /// 组装 luac2c 的参数
  List<String> l2cArgs(String luacPath, String outC) {
    final args = <String>[luacPath];
    if (mode == layoutSeed) {
      args.addAll(['--seed', seed.trim().isEmpty ? '0' : seed.trim()]);
    }
    if (mode == layoutPlain) args.add('--static');
    args.addAll(['-o', outC]);
    if (noPool) args.add('--no-pool');
    if (annotate) args.add('--annotate');
    if (!guard) args.add('--no-guard');
    // 登录后把账号标识交给 luac2c：产物里会嵌入这个账号的指纹，
    // 之后拿 luac2c --who 就能从任意一份副本反查归属。
    final uid = AccountCtl.I.uid;
    if (uid != null && uid.isNotEmpty) args.addAll(['--fingerprint', uid]);
    return args;
  }
}

/// 一个源文件派生出来的四条中间/产物路径
class BuildPaths {
  final String src;
  final String dir;
  final String stem;
  final String luac;
  final String c;
  final String exe;
  BuildPaths(this.src, this.dir, this.stem)
      : luac = '$dir${Platform.pathSeparator}$stem.luac',
        c = '$dir${Platform.pathSeparator}${stem}_out.c',
        exe = '$dir${Platform.pathSeparator}${stem}_out.exe';

  factory BuildPaths.of(String src) {
    final sep = Platform.pathSeparator;
    final dir = src.contains(sep)
        ? src.substring(0, src.lastIndexOf(sep))
        : Directory.current.path;
    final base = src.split(sep).last;
    final dot = base.lastIndexOf('.');
    return BuildPaths(src, dir, dot > 0 ? base.substring(0, dot) : base);
  }
}

/// 单个文件的构建器。
///
/// 取消检查和日志收集都在这里：日志先攒进局部缓冲，跑完一次性返回，
/// 这样并发处理多个文件时日志不会互相穿插。
class FileBuild {
  final Tools tools;
  final String srcPath;
  final bool full;
  final bool Function() cancelled;
  final BuildOptions opts;

  final List<String> _out = <String>[];
  final Stopwatch _sw = Stopwatch();

  FileBuild({
    required this.tools,
    required this.srcPath,
    required this.full,
    required this.cancelled,
    required this.opts,
  });

  void _p(String s) => _out.add(s);

  void _pOut(StepResult r) {
    if (r.output.trim().isNotEmpty) {
      _p('      ${r.output.trim().replaceAll('\n', '\n      ')}');
    }
  }

  void _bailIfCancelled() {
    if (cancelled()) throw '已取消';
  }

  Future<FileOutcome> run() async {
    _sw.start();
    _p('');
    _p('──── ${_stamp()}  $srcPath');

    final paths = BuildPaths.of(srcPath);
    _cleanStale(paths);

    var ok = false;
    try {
      await _stepLuac(paths);
      await _stepTranslate(paths);
      if (!full) {
        _p('✓ C 源码已生成 → ${paths.c}');
        ok = true;
      } else {
        await _stepCompile(paths);
        ok = await _stepRunAndCompare(paths);
      }
    } catch (e) {
      _p('      ✗ $e');
      _p('✗ 失败：$srcPath');
      ok = false;
    }
    _sw.stop();
    _p('      [${(_sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s]');
    return FileOutcome(srcPath, ok, _out, ms: _sw.elapsedMilliseconds);
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} '
        '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  /// 清理上一轮的中间产物：避免用陈旧结果"假通过"
  void _cleanStale(BuildPaths p) {
    for (final path in <String>[p.luac, p.c, if (full) p.exe]) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {/* 删不掉不影响后续，写入会覆盖 */}
    }
  }

  Future<void> _stepLuac(BuildPaths p) async {
    _p('[1/5] luac  编译字节码');
    _bailIfCancelled();
    final r = await runCapture(tools.luac, ['-o', p.luac, p.src], p.dir,
        timeout: const Duration(seconds: 30), isCancelled: cancelled);
    _pOut(r);
    if (r.exitCode != 0) throw 'luac 退出码 ${r.exitCode}';
    if (!File(p.luac).existsSync()) throw 'luac 未生成 ${p.luac}';
    _p('      → ${p.luac}  (${r.ms}ms)');
  }

  Future<void> _stepTranslate(BuildPaths p) async {
    _p('[2/5] luac2c  翻译为 C');
    _bailIfCancelled();
    final r = await runCapture(tools.l2c, opts.l2cArgs(p.luac, p.c), p.dir,
        timeout: const Duration(seconds: 60), isCancelled: cancelled);
    _pOut(r);
    if (r.exitCode != 0) throw 'luac2c 退出码 ${r.exitCode}';
    if (!File(p.c).existsSync()) throw 'luac2c 未生成 ${p.c}';
    _p('      → ${p.c}  (${r.ms}ms)');
    if (AccountCtl.I.loggedIn) {
      _p('      ID ${AccountCtl.I.fingerprint}（账号 ${AccountCtl.I.name}）');
    }
  }

  Future<void> _stepCompile(BuildPaths p) async {
    _p('[3/5] gcc  编译链接');
    _bailIfCancelled();
    final r = await runCapture(
        tools.gcc,
        [
          p.c,
          '-I',
          tools.inc1,
          '-I',
          tools.inc2,
          '-std=c99',
          '-w',
          '-O0',
          // -pipe：用管道代替临时文件，减少磁盘 IO
          if (Platform.isWindows) '-pipe',
          '-o',
          p.exe,
          tools.lib,
          '-lm'
        ],
        p.dir,
        timeout: const Duration(seconds: 180),
        isCancelled: cancelled);
    _pOut(r);
    if (r.exitCode != 0) throw 'gcc 退出码 ${r.exitCode}';
    if (!File(p.exe).existsSync()) throw 'gcc 未生成 ${p.exe}';
    _p('      → ${p.exe}  (${r.ms}ms)');
  }

  /// 运行生成物并与 lua.exe 的输出、退出码比对
  Future<bool> _stepRunAndCompare(BuildPaths p) async {
    _p('[4/5] 运行生成物');
    _bailIfCancelled();
    final gen = await runCapture(p.exe, [], p.dir,
        timeout: const Duration(seconds: 30), isCancelled: cancelled);
    if (gen.timeout) throw '产物运行超时，已终止';

    _p('[5/5] 与 lua.exe 输出比对');
    _bailIfCancelled();
    final ref = await runCapture(tools.lua, [p.src], p.dir,
        timeout: const Duration(seconds: 30), isCancelled: cancelled);
    if (ref.timeout) throw 'lua.exe 运行超时，已终止';
    // 规范化换行：Windows 下 CRLF/LF 差异不应判为失败
    final genOut = normalizeNewlines(gen.output);
    final refOut = normalizeNewlines(ref.output);
    if (genOut.isNotEmpty) {
      _p('      生成物> ${genOut.replaceAll('\n', '\n      ')}');
    }
    if (refOut.isNotEmpty) {
      _p('      lua.exe> ${refOut.replaceAll('\n', '\n      ')}');
    }
    final same = genOut == refOut && gen.exitCode == ref.exitCode;
    if (same) {
      _p('      ✓ 输出一致，退出码一致 (${gen.exitCode})');
      _p('✓ 通过：$srcPath');
    } else {
      _p('      ✗ 不一致（exit ${gen.exitCode} vs ${ref.exitCode}）');
      _p('✗ 失败：$srcPath');
    }
    return same;
  }
}
