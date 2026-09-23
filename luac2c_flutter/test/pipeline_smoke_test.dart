// 无界面跑一遍完整流水线：探测工具 -> 加入项目 test 目录样例 -> 构建并比对
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:luac2c_client/pipeline.dart';
import 'package:luac2c_client/tools.dart';

void main() {
  test('samples: build and compare', () async {
    final ctl = PipelineCtl();
    ctl.tools = findTools();
    ctl.addFiles(ctl.sampleFiles());
    final n = ctl.files.length;
    // 无界面跑，直接打到测试输出最直观
    print('tools=${ctl.tools.signature}');
    print('files=$n');
    expect(n, greaterThan(0));

    final sw = Stopwatch()..start();
    await ctl.run(full: true);
    sw.stop();

    final ok = ctl.results.values.where((v) => v).length;
    print('done=${ctl.doneCount}/${ctl.totalCount} ok=$ok in '
        '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
    print('status=${ctl.status}');
    print('log lines=${ctl.log.lines.length}');
    ctl.dispose();
    expect(ok, n);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
