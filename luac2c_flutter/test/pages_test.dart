// 页面渲染冒烟：重构 UI 之后，确认两个页面还能正常搭建出来（无运行时异常）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luac2c_client/home_page.dart';
import 'package:luac2c_client/mine_page.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2D74B5))),
      home: child,
    );

void main() {
  testWidgets('home page renders', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const HomePage()));
    await tester.pumpAndSettle();

    expect(find.text('源文件'), findsOneWidget);
    expect(find.text('代码防护'), findsOneWidget);
    expect(find.text('工具链'), findsOneWidget);
    expect(find.text('一键构建'), findsOneWidget);
    expect(find.text('加入示例脚本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 窄窗口下要切成单栏，否则日志区会被压到 0 高度（这正是"终端显示不出来"
  // 的成因）。断言的是布局分支走通且没有溢出。
  testWidgets('home page survives a narrow window', (tester) async {
    tester.view.physicalSize = const Size(760, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const HomePage()));
    await tester.pumpAndSettle();

    expect(find.text('一键构建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mine page renders login form', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const MinePage()));
    await tester.pumpAndSettle();

    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('记住我'), findsOneWidget);
    expect(find.text('关于账号与指纹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
