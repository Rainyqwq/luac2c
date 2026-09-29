// 比对归一化：SMOKE（刻意不确定）与 SKIP（能力跳过）行不参与 diff。
// 这两类行是测试脚本自己声明"允许两边不同"的，早期只用换行归一化，
// 于是一份产物跳过协程 yield 用例时整份文件被判失败。
import 'package:flutter_test/flutter_test.dart';
import 'package:luac2c_client/runner.dart';

void main() {
  test('CRLF 与尾随空白不影响比对', () {
    expect(normalizeForCompare('a\r\nb\r\n'), normalizeForCompare('a\nb\n'));
    expect(normalizeForCompare('a  \nb\t'), normalizeForCompare('a\nb'));
  });

  test('SMOKE 行被剔除', () {
    const gen = 'Lua 5.5\nSMOKE gc-count-MB>0:\ttrue\nRESULT: 1 passed, 0 failed';
    const ref = 'Lua 5.5\nSMOKE gc-count-MB>0:\ttrue\nRESULT: 1 passed, 0 failed';
    expect(normalizeForCompare(gen), normalizeForCompare(ref));
    expect(normalizeForCompare(gen), isNot(contains('SMOKE')));
  });

  test('SKIP 行不计入差异（跳过与否取决于产物能力）', () {
    const gen = 'Lua 5.5\n'
        'SKIP coroutine-yield cases (yield across a C-call boundary is unsupported)\n'
        'RESULT: 222 passed, 0 failed\n'
        'ALL TESTS PASSED';
    const ref = 'Lua 5.5\n'
        'RESULT: 232 passed, 0 failed\n'
        'ALL TESTS PASSED';
    // 222 vs 232 仍是真实差异，会被抓到
    expect(normalizeForCompare(gen), isNot(normalizeForCompare(ref)));
    // 计数一致时，仅多一行 SKIP 不应判为差异
    const gen2 = 'Lua 5.5\n'
        'SKIP coroutine-yield cases (yield across a C-call boundary is unsupported)\n'
        'RESULT: 232 passed, 0 failed\n'
        'ALL TESTS PASSED';
    expect(normalizeForCompare(gen2), normalizeForCompare(ref));
  });

  test('真实输出差异不被掩盖', () {
    expect(normalizeForCompare('a\nb\nc'), isNot(normalizeForCompare('a\nX\nc')));
    expect(normalizeForCompare('a\nb'), isNot(normalizeForCompare('a\nb\nc')));
  });
}
