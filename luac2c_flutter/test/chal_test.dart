// 挑战应答的接线：参数怎么传、槽位怎么解析、边界怎么处理。
//
// 这一层值得单独测，因为它牵着两处外部状态 —— luac2c 的命令行，以及产物
// 自己的 --chal-respond 入口 —— 而两处都不接受"差不多就行"。
import 'package:flutter_test/flutter_test.dart';
import 'package:luac2c_client/pipeline.dart';
import 'package:luac2c_client/steps.dart';

void main() {
  group('l2cArgs', () {
    test('chal 关闭时不传该选项', () {
      const o = BuildOptions();
      expect(o.l2cArgs('a.luac', 'out.c'), isNot(contains('--chal')));
    });

    test('chal 开启时传槽位', () {
      const o = BuildOptions(chal: 5);
      final a = o.l2cArgs('a.luac', 'out.c');
      expect(a, containsAllInOrder(['--chal', '5']));
    });

    // 不混淆那一档关掉的正是防护，留着应答会让用户以为这一档也有防护。
    test('不混淆模式下不传 chal', () {
      const o = BuildOptions(mode: layoutPlain, chal: 5);
      expect(o.l2cArgs('a.luac', 'out.c'), isNot(contains('--chal')));
    });

    test('槽位 0 是合法值，不是"没填"', () {
      const o = BuildOptions(chal: 0);
      expect(o.l2cArgs('a.luac', 'out.c'), containsAllInOrder(['--chal', '0']));
    });
  });

  group('槽位解析', () {
    late PipelineCtl ctl;
    setUp(() => ctl = PipelineCtl());
    tearDown(() => ctl.dispose());

    test('空输入退回 0', () {
      ctl.chalSlot.text = '';
      expect(ctl.chalIndex, 0);
    });

    test('负数退回 0', () {
      ctl.chalSlot.text = '-3';
      expect(ctl.chalIndex, 0);
    });

    test('非数字退回 0', () {
      ctl.chalSlot.text = 'abc';
      expect(ctl.chalIndex, 0);
    });

    test('正常值原样取用', () {
      ctl.chalSlot.text = ' 7 ';
      expect(ctl.chalIndex, 7);
    });
  });

  group('状态清理', () {
    late PipelineCtl ctl;
    setUp(() => ctl = PipelineCtl());
    tearDown(() => ctl.dispose());

    test('清空文件列表会丢掉上一次的应答', () {
      ctl.chalAnswer = 'DEADBEEF';
      ctl.chalExe = r'C:\tmp\x_out.exe';
      ctl.clearFiles();
      expect(ctl.chalAnswer, isNull);
      expect(ctl.chalExe, isNull);
    });

    test('重新开启 chal 会作废旧应答', () {
      ctl.chalAnswer = 'DEADBEEF';
      ctl.setChal(true);
      expect(ctl.chalAnswer, isNull);
    });
  });
}
