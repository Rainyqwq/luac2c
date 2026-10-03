// 构建流水线的控制层（不含任何 Widget）。
//
// 主页只负责把用户操作转给 [PipelineCtl]、并把它的状态渲染出来；
// 文件列表、并发调度、子进程编排、状态文案都在这里。这样 UI 与流程逻辑
// 各自独立演进，也便于以后加命令行/无界面模式。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'log_store.dart';
import 'runner.dart';
import 'steps.dart';
import 'tools.dart';
import 'win_dialog.dart';

// 布局常量（layoutRandom / layoutSeed / layoutPlain）与单文件构建步骤都在
// steps.dart 里，这里直接复用，不再各自定义一份。

/// 状态栏的语义等级。写在类外 —— Dart 不允许在类体内声明 enum。
enum Level { idle, working, good, bad }

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

  /// 状态栏配色不靠"文案里有没有某个关键词"判断，那是隐式约定 ——
  /// 改一句提示词就可能让配色悄悄失配。改成由写入方显式声明。
  Level statusLevel = Level.idle;

  // ---- 输出选项 ----
  int mode = layoutRandom;
  final TextEditingController seed = TextEditingController(text: '0');
  bool noPool = false;
  bool annotate = false;
  /// 运行时防护：反调试 + 代码/常量完整性自校验（关闭等价于 --no-guard）
  bool guard = true;

  // ---- 挑战应答 ----
  /// 是否让产物带上应答能力（--chal）。
  bool chal = false;
  /// 槽位：常量池条目下标，0 起。取值越大覆盖的密文范围越广（链值只含
  /// 该条目之前的字节），所以默认给一个靠后的值而不是 0。
  final TextEditingController chalSlot = TextEditingController(text: '64');
  /// 取最近一次应答（--chal-respond 的输出），null 表示还没取过。
  String? chalAnswer;
  /// 最近一次导出的校验参数（id / chal_nonce / chal_chain / poolsig）
  String? chalParams;
  /// 刚构建完的产物路径，应答要从它身上取。
  String? chalExe;

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

  void _setStatus(String s, {Level level = Level.idle, bool force = false}) {
    status = s;
    statusLevel = level;
    _touch(force: force);
  }

  // ---------------------------------------------------------------- 生命周期
  /// 启动工具链探测（轮询会遍历 PATH 做 existsSync，因此
  /// ① 间隔放宽到 5s；② 流水线运行期间跳过 —— 此时工具不会变，也别抢 IO）
  void start() {
    tools = findTools();
    _touch();
    log.add('配置文件遍历完成。选择 .lua 文件，或直接把文件拖进窗口。');
    // 原生文件对话框的结果从这条回调进来
    WinDialog.I.ensureHandler(addFiles);
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
    chalSlot.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 文件列表
  /// 把外部给进来的路径加入待处理列表（去重、只收存在的文件）
  ///
  /// 被拒的路径要说出原因。原先一律 `continue` 静默丢弃，用户选完文件
  /// 看列表没变，只能猜自己是不是没选对。
  void addFiles(List<String> paths) {
    var added = 0;
    final rejected = <String>[];
    var dup = 0;
    for (final p in paths) {
      final t = p.trim();
      if (t.isEmpty) continue;
      if (!File(t).existsSync()) {
        rejected.add(t);
        continue;
      }
      if (files.contains(t)) {
        dup++;
        continue;
      }
      files.add(t);
      added++;
    }
    if (added > 0) {
      log.add('已添加 $added 个文件（当前共 ${files.length} 个）');
    }
    if (dup > 0) {
      log.add('· 跳过 $dup 个已在列表中的文件');
    }
    if (rejected.isNotEmpty) {
      // 只记前几个，全量打出来日志会被路径刷爆
      final shown = rejected.take(3).map((e) => _baseName(e)).join('、');
      log.add('! 跳过 ${rejected.length} 个不存在的文件：$shown'
          '${rejected.length > 3 ? ' 等' : ''}');
      unawaited(_notice('已跳过 ${rejected.length} 个不存在的文件'));
    }
    if (added > 0 || dup > 0 || rejected.isNotEmpty) _touch();
  }

  /// 取路径的文件名部分。日志与界面用短名，长路径没有信息量。
  static String _baseName(String path) {
    final i = path.lastIndexOf(r'\');
    final j = path.lastIndexOf('/');
    final k = i > j ? i : j;
    return k >= 0 ? path.substring(k + 1) : path;
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
    // 产物没了，上一次应答与参数也就没有意义（它们对应的是那份产物）。
    chalAnswer = null;
    chalParams = null;
    chalExe = null;
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

  /// 多选文件。走 runner 里的 IFileOpenDialog（资源管理器同款对话框）。
  ///
  /// 原先的实现是拉起 powershell.exe + WinForms，既糊又容易被主窗口挡住，
  /// 详见 win_dialog.dart 顶部的说明。结果通过 WinDialog 的回调进来，
  /// 这里只负责把请求发出去。
  Future<void> pickFiles() async {
    try {
      await WinDialog.I.pickFiles();
    } catch (e) {
      await _notice('无法打开文件对话框：$e');
    }
  }

  void openOutDir() {
    // Windows 的习惯是"定位并选中"，不是"打开目录让你自己找"。
    // 列表为空时退回根目录，只开目录不加 /select。
    if (files.isEmpty) {
      Process.run('explorer.exe', [tools.root]);
      return;
    }
    WinDialog.I.revealInExplorer(files.first);
  }

  /// 在资源管理器中定位到指定文件（列表行双击、右键菜单都走这里）
  void revealFile(String path) => WinDialog.I.revealInExplorer(path);

  /// 复制完整路径到剪贴板
  Future<void> copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    _setStatus('路径已复制到剪贴板', level: Level.good);
  }

  /// 日志面板复制完成后回写状态条
  void noteLogCopied() =>
      _setStatus('日志已复制到剪贴板', level: Level.good);

  /// 应答复制完成
  void noteChalCopied() =>
      _setStatus('应答已复制到剪贴板', level: Level.good);

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

  // ------------------------------------------------------------ 挑战应答
  void setChal(bool v) {
    if (chal == v) return;
    chal = v;
    // 换了一次构建，旧的应答与参数都不再对应
    if (v) {
      chalAnswer = null;
      chalParams = null;
    }
    _touch();
  }

  /// 槽位下标。写坏了就退回 0 —— 槽位越界时 luac2c 会自己钳到末项并告警，
  /// 但那是个没有人会看的告警，所以在这里先挡住。
  int get chalIndex {
    final v = int.tryParse(chalSlot.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 导出服务端要记的三个校验值（--chal-out）。
  ///
  /// 让程序自己打出来而不是手抄：抄错一位，服务端就会拒掉一份合法产物，
  /// 而这种错误在现场极难定位。
  Future<void> fetchChalParams() async {
    final exe = chalExe;
    if (exe == null || !File(exe).existsSync()) {
      _setStatus('还没有可验证的产物，先构建一次', level: Level.bad);
      return;
    }
    final r = await runCapture(exe, ['--chal-out'], null,
        timeout: const Duration(seconds: 20));
    if (r.exitCode != 0 || r.output.trim().isEmpty) {
      _setStatus('产物未提供校验参数（可能不是带应答构建的）', level: Level.bad);
      return;
    }
    final params = r.output.trim();
    chalParams = params;
    log.add('校验参数：\n${params.replaceAll('\n', '\n  ')}');
    _setStatus('校验参数已记入日志', level: Level.good);
  }

  /// 问产物要一次应答。
  ///
  /// nonce 由调用方给（真实部署里是服务端刚发来的那一个）；这里用时钟
  /// 派生一个，仅仅是为了让"按一下有反应"。应答本身与运行时刻无关 ——
  /// 同样的 nonce 在同样的产物上永远得到同样的结果，这正是服务端能
  /// 离线校验的前提。
  Future<void> fetchChalAnswer() async {
    final exe = chalExe;
    if (exe == null || !File(exe).existsSync()) {
      _setStatus('还没有可验证的产物，先构建一次', level: Level.bad);
      return;
    }
    final nonce = DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;
    final r = await runCapture(exe, ['--chal-respond', '$nonce'], null,
        timeout: const Duration(seconds: 20));
    final out = r.output.trim();
    if (r.exitCode != 0 || out.isEmpty) {
      _setStatus('产物未提供应答（可能不是带应答构建的）', level: Level.bad);
      return;
    }
    chalAnswer = out;
    log.add('挑战应答：nonce=$nonce 应答=$out');
    _setStatus('应答 $out（nonce $nonce）', level: Level.good);
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
        // 主程序不认识 --chal 时不发这个选项，否则整步会以
        // "unknown option" 失败 —— 客户端可以配到旧版 luac2c。
        chal: (chal && tools.l2cChal) ? chalIndex : -1,
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
          if (o.ok) {
            pass++;
            // 记下最后一份成功的产物：挑战应答要从它身上取，而"仅生成 C"
            // 那条路不产生可执行文件。
            if (full) chalExe = BuildPaths.of(f).exe;
          }
          if (_disposed) return;
          doneCount++;
          results[f] = o.ok;
          _setStatus('进度 $doneCount/$totalCount —— 已通过 $pass',
              level: Level.working);
        }
      }

      await Future.wait(List.generate(workers, (_) => worker()));
      if (cancel) log.add('■ 已停止，剩余任务未执行');
    } catch (e) {
      log.add('! 流程异常：$e');
      _setStatus('流程异常：$e', level: Level.bad);
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
      _setStatus('已停止：完成 $done/$totalCount，通过 $pass',
          level: Level.idle);
      log.add('■ 已停止（耗时 ${secs}s）');
    } else if (failed == 0) {
      _setStatus('批量通过：$pass/$done（${secs}s）', level: Level.good);
      log.add('✓ 批量全部通过（$pass/$done，耗时 ${secs}s）');
    } else {
      _setStatus('批量完成：$pass 通过，$failed 失败（${secs}s）',
          level: failed > 0 ? Level.bad : Level.good);
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
    _setStatus('正在停止…', level: Level.working, force: true);
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
        _setStatus('luac2c.exe 已重新编译', level: Level.good);
      } else {
        log.add('      ✗ gcc 退出码 ${r.exitCode}');
        _setStatus('重新编译失败', level: Level.bad);
      }
    } catch (e) {
      log.add('      ✗ $e');
      _setStatus('重新编译失败', level: Level.bad);
    } finally {
      busy = false;
      _touch();
    }
  }

  /// 一次性提示：写日志 + 改状态条。
  ///
  /// 原来还会弹 SnackBar，问题是它从底部浮起来正好压在状态条上 ——
  /// 而状态条当时在左栏滚动区最底部，不滚就看不见，等于提示把结果盖住了。
  /// 现在状态条固定在窗口底栏，提示直接写在那里，不再有浮层。
  Future<void> _notice(String m, {Level level = Level.bad}) async {
    log.add('! $m');
    _setStatus(m, level: level);
  }
}
