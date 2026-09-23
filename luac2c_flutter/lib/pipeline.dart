// 构建流水线的控制层（不含任何 Widget）。
//
// 主页只负责把用户操作转给 [PipelineCtl]、并把它的状态渲染出来；
// 文件列表、并发调度、子进程编排、状态文案都在这里。这样 UI 与流程逻辑
// 各自独立演进，也便于以后加命令行/无界面模式。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'log_store.dart';
import 'runner.dart';
import 'steps.dart';
import 'tools.dart';

// 布局常量（layoutRandom / layoutSeed / layoutPlain）与单文件构建步骤都在
// steps.dart 里，这里直接复用，不再各自定义一份。

class PipelineCtl extends ChangeNotifier {
  PipelineCtl();

  final LogStore log = LogStore();

  // ---- 工具链 ----
  Tools tools = Tools();
  Timer? _toolsTimer;

  // ---- 批量任务 ----
  final List<String> files = <String>[];
  final Map<String, bool> results = <String, bool>{};
  int doneCount = 0;
  int totalCount = 0;
  bool busy = false;
  bool cancel = false;
  String status = '就绪';

  // ---- 输出选项 ----
  int mode = layoutRandom;
  final TextEditingController seed = TextEditingController(text: '0');
  bool noPool = false;
  bool annotate = false;
  /// 运行时防护：反调试 + 代码/常量完整性自校验（关闭等价于 --no-guard）
  bool guard = true;

  /// UI 侧的提示回调（弹 SnackBar）。控制层不持有 BuildContext。
  void Function(String message)? onNotice;

  bool _disposed = false;
  Timer? _notifyTimer;

  /// 通知监听者（dispose 之后一律不再通知，避免 assertion）
  ///
  /// 批量处理时每完成一个文件就会刷新一次进度，直接重建界面的话 UI 线程
  /// 会被密集重建占住（同一时刻还有多个 gcc 在抢 CPU）。因此 busy 期间把
  /// 通知合并成最多 150ms 一次；busy 的进入/退出与收尾状态立即通知，
  /// 保证按钮、进度条、状态条的最终值都准确。
  void _touch({bool force = false}) {
    if (_disposed) return;
    if (!force && busy) {
      _notifyTimer ??= Timer(const Duration(milliseconds: 150), () {
        _notifyTimer = null;
        if (!_disposed) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  void _setStatus(String s, {bool force = false}) {
    status = s;
    _touch(force: force);
  }

  // ---------------------------------------------------------------- 生命周期
  /// 启动工具链探测（轮询会遍历 PATH 做 existsSync，因此
  /// ① 间隔放宽到 5s；② 流水线运行期间跳过 —— 此时工具不会变，也别抢 IO）
  void start() {
    tools = findTools();
    _touch();
    log.add('配置文件遍历完成。选择 .lua 文件，或直接把文件拖进窗口。');
    _toolsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (busy || _disposed) return;
      final t = findTools();
      if (t.signature != tools.signature) {
        tools = t;
        _touch();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _toolsTimer?.cancel();
    log.flush();
    log.close();
    seed.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 文件列表
  /// 把外部给进来的路径加入待处理列表（去重、只收存在的文件）
  void addFiles(List<String> paths) {
    var added = 0;
    for (final p in paths) {
      final t = p.trim();
      if (t.isEmpty) continue;
      if (!File(t).existsSync()) continue;
      if (files.contains(t)) continue;
      files.add(t);
      added++;
    }
    if (added > 0) {
      log.add('已添加 $added 个文件（当前共 ${files.length} 个）');
      _touch();
    }
  }

  void removeFileAt(int i) {
    if (i < 0 || i >= files.length) return;
    results.remove(files[i]);
    files.removeAt(i);
    _touch();
  }

  void clearFiles() {
    files.clear();
    results.clear();
    doneCount = 0;
    totalCount = 0;
    _touch();
  }

  /// 项目 test 目录下的用例（方便一键批量试跑）
  List<String> sampleFiles() {
    final d = Directory('${tools.root}\\test');
    if (!d.existsSync()) return const <String>[];
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.lua'))
        .map((f) => f.path)
        .toList();
  }

  /// 多选文件（Windows 文件对话框，Multiselect）
  Future<void> pickFiles() async {
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
    if (r.exitCode == 0 && lines.isNotEmpty) addFiles(lines);
  }

  void openOutDir() {
    final p = files.isNotEmpty ? files.first : '';
    final dir =
        p.contains(r'\') ? p.substring(0, p.lastIndexOf(r'\')) : tools.root;
    Process.run('explorer.exe', [dir]);
  }

  /// 日志面板复制完成后回写状态条
  void noteLogCopied() => _setStatus('日志已复制到剪贴板');

  // ---------------------------------------------------------------- 选项
  void setMode(int v) {
    mode = v;
    _touch();
  }

  void setGuard(bool v) {
    guard = v;
    _touch();
  }

  void setNoPool(bool v) {
    noPool = v;
    _touch();
  }

  void setAnnotate(bool v) {
    annotate = v;
    _touch();
  }

  /// 三种布局的一句话说明（免得「随机 / 固定种子 / 不混淆」看着没头没尾）
  String get modeHint {
    switch (mode) {
      case layoutSeed:
        return '默认：静态Seed不变';
      case layoutPlain:
        return '不混淆：不注入静态&动态防护功能';
      default:
        return '随机：每次转译更换随机Seed';
    }
  }

  /// 当前选项的快照：传给 [FileBuild]，让它不必依赖界面状态
  BuildOptions get options => BuildOptions(
        mode: mode,
        seed: seed.text,
        noPool: noPool,
        annotate: annotate,
        guard: guard,
      );

  // ---------------------------------------------------------------- 批量流水线
  Future<void> run({required bool full}) async {
    if (busy) return;
    if (files.isEmpty) {
      await _notice('请先添加 .lua 文件（可多选，或把多个文件拖进窗口）');
      return;
    }
    // 前置校验：一次检查全部需要的工具，避免跑到一半才发现缺工具
    final t = findTools();
    if (t.signature != tools.signature) {
      tools = t;
      _touch();
    }
    final missing = t.missing(full: full);
    if (missing.isNotEmpty) {
      await _notice(
          '缺少工具：${missing.join('、')}（根目录：${tools.root}，已尝试系统 PATH）');
      return;
    }
    // 剔除已失效的文件，避免列表里有被删除的路径
    final stale = files.where((f) => !File(f).existsSync()).toList();
    if (stale.isNotEmpty) {
      files.removeWhere((f) => stale.contains(f));
      log.add('! 已忽略 ${stale.length} 个不存在的文件');
    }
    if (files.isEmpty) {
      await _notice('文件列表为空或文件均已不存在');
      return;
    }

    busy = true;
    cancel = false;
    results.clear();
    totalCount = files.length;
    doneCount = 0;
    _touch(force: true); // 按钮与进度条要立刻进入忙碌态

    final sw = Stopwatch()..start();
    var pass = 0;
    try {
      // 并发工作池：每个文件要串行跑 5 个子进程，但文件之间互不依赖，
      // 并行处理能把 luac/gcc 的等待时间重叠起来，批量场景提速明显。
      final queue = List<String>.from(files);
      var cursor = 0;
      final workers = _workerCount < queue.length ? _workerCount : queue.length;
      log.add('▶ 开始处理 ${queue.length} 个文件（并发 $workers，'
          '${Platform.numberOfProcessors} 核）');

      Future<void> worker() async {
        while (!cancel) {
          if (cursor >= queue.length) return;
          // Dart 单线程事件循环：读与自增之间没有 await，并发安全
          final f = queue[cursor++];
          final o = await _processOne(f, full);
          log.addAll(o.lines); // 整段入库，避免逐行触发刷新
          if (o.ok) pass++;
          if (_disposed) return;
          doneCount++;
          results[f] = o.ok;
          _setStatus('进度 $doneCount/$totalCount —— 已通过 $pass');
        }
      }

      await Future.wait(List.generate(workers, (_) => worker()));
      if (cancel) log.add('■ 已停止，剩余任务未执行');
    } catch (e) {
      log.add('! 流程异常：$e');
      _setStatus('流程异常：$e');
    } finally {
      log.flush();
      busy = false;
      _touch();
    }
    sw.stop();
    final done = doneCount;
    final failed = done - pass;
    final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
    if (cancel) {
      _setStatus('已停止：完成 $done/$totalCount，通过 $pass');
      log.add('■ 已停止（耗时 ${secs}s）');
    } else if (failed == 0) {
      _setStatus('批量通过：$pass/$done（${secs}s）');
      log.add('✓ 批量全部通过（$pass/$done，耗时 ${secs}s）');
    } else {
      _setStatus('批量完成：$pass 通过，$failed 失败（${secs}s）');
      log.add('✗ 批量结束：失败 $failed 个，通过 $pass 个（耗时 ${secs}s）');
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
  void stop() {
    if (!busy) return;
    cancel = true;
    killActiveProcesses(); // 立刻终止正在跑的子进程，不等它们自然结束
    _setStatus('正在停止…', force: true);
    log.add('! 收到停止请求，已终止子进程');
    log.flush();
  }

  /// 处理单个文件。具体五步在 steps.dart 的 [FileBuild] 里，
  /// 这里只负责把当前的工具链与选项交给它，并把结果原样返回。
  Future<FileOutcome> _processOne(String srcPath, bool full) => FileBuild(
        tools: tools,
        srcPath: srcPath,
        full: full,
        cancelled: () => cancel,
        opts: options,
      ).run();

  /// 用 gcc 重新编译 luac2c.c，生成新的 luac2c.exe
  Future<void> rebuild() async {
    if (busy) return;
    busy = true;
    _touch(force: true);
    log.add('');
    log.add('[重新编译] gcc luac2c.c -O2 -o luac2c.exe');
    try {
      if (!tools.gccOk) throw '找不到 gcc.exe';
      final r = await runCapture(tools.gcc, [
        '${tools.root}\\luac2c.c',
        '-O2',
        '-o',
        '${tools.root}\\luac2c.exe',
        '-lm'
      ], tools.root);
      final txt = r.output.trim();
      if (txt.isNotEmpty) log.add('      ${txt.replaceAll('\n', '\n      ')}');
      if (r.exitCode == 0) {
        log.add('      ✓ luac2c.exe 已重新编译');
        _setStatus('luac2c.exe 已重新编译');
      } else {
        log.add('      ✗ gcc 退出码 ${r.exitCode}');
        _setStatus('重新编译失败');
      }
    } catch (e) {
      log.add('      ✗ $e');
      _setStatus('重新编译失败');
    } finally {
      busy = false;
      _touch();
    }
  }

  /// 一次性提示：写日志 + 改状态条 + 交给 UI 弹 SnackBar
  Future<void> _notice(String m) async {
    log.add('! $m');
    _setStatus(m);
    onNotice?.call(m);
  }
}
