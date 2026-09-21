// 子进程执行层：超时 / 取消 / 输出截断 / GBK 容错解码。
//
// 流水线里每一步（luac、luac2c、gcc、运行产物、lua.exe 参考实现）都走
// 这里的 [runCapture]，因此所有健壮性策略只在这一处维护。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 子进程默认超时（防止某个环节卡死导致整条流水线永挂）
const Duration kStepTimeout = Duration(seconds: 60);

/// 单条命令最多收集的输出行数（防止日志爆炸拖垮 UI 与内存）
const int kMaxOutputLines = 400;

/// 子进程执行结果：退出码 + 输出 + 耗时 + 是否超时
class StepResult {
  final int exitCode;
  final String output;
  final int ms;
  final bool timeout;
  StepResult(this.exitCode, this.output, {this.ms = 0, this.timeout = false});
}

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
String normalizeNewlines(String s) =>
    trimTail(s.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));

String trimTail(String s) => s.replaceFirst(RegExp(r'[\s]+$'), '');
