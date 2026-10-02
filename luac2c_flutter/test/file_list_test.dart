// 文件列表的取舍逻辑：静默丢弃是 Windows 用户最恨的一种行为。
// addFiles 以前对不存在的路径直接 continue，选完文件看列表没变、
// 也没任何提示，用户只能猜自己是不是选错了。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:luac2c_client/pipeline.dart';

void main() {
  late PipelineCtl ctl;
  late List<String> notices;

  setUp(() {
    ctl = PipelineCtl();
    notices = <String>[];
    ctl.onNotice = (m) => notices.add(m);
  });

  tearDown(() => ctl.dispose());

  test('accepts an existing file', () {
    final f = File.createTempSync('ok', '.lua');
    addTearDown(() => f.deleteSync());
    ctl.addFiles([f.path]);
    expect(ctl.files, [f.path]);
    expect(notices, isEmpty, reason: '正常路径不该弹提示');
  });

  test('reports files that do not exist instead of dropping them', () {
    final missing = r'C:\definitely\not\here\a.lua';
    ctl.addFiles([missing]);
    expect(ctl.files, isEmpty);
    // 关键：用户得知道为什么没加进来
    expect(notices, isNotEmpty);
    expect(notices.first, contains('1'));
  });

  test('mixes good and bad paths without losing the good ones', () {
    final f = File.createTempSync('ok', '.lua');
    addTearDown(() => f.deleteSync());
    ctl.addFiles([f.path, r'C:\nope\b.lua']);
    expect(ctl.files, [f.path], reason: '好路径必须照常收下');
    expect(notices, isNotEmpty, reason: '坏路径必须说一声');
  });

  test('duplicate is skipped quietly', () {
    final f = File.createTempSync('ok', '.lua');
    addTearDown(() => f.deleteSync());
    ctl.addFiles([f.path]);
    notices.clear();
    ctl.addFiles([f.path]);
    expect(ctl.files.length, 1);
    // 重复不是错误，只是没变化，不必弹提示打扰
    expect(notices, isEmpty);
  });

  test('empty and blank paths are ignored', () {
    ctl.addFiles(['', '   ', r'C:\nope\blank.lua']);
    expect(ctl.files, isEmpty);
  });
}
