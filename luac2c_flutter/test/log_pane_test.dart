// 日志面板渲染：逐行虚拟化后仍然能正确布局、滚动到底、可选中
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luac2c_client/log_pane.dart';
import 'package:luac2c_client/widgets.dart';

void main() {
  testWidgets('log pane renders many lines', (tester) async {
    final log = LogStore();
    for (var i = 0; i < 500; i++) {
      log.add('line $i -----------------------------------------------');
    }
    log.flush();

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2D74B5))),
      home: Scaffold(body: LogPane(log: log, onCopied: () {})),
    ));
    await tester.pumpAndSettle();

    // 默认贴底：末行在视口内、首行不在（说明确实只布局了可见行）
    expect(find.text('line 499 -----------------------------------------------'),
        findsOneWidget);
    expect(find.text('line 0 -----------------------------------------------'),
        findsNothing);
    expect(tester.takeException(), isNull);

    // 滚到顶后首行应出现，末行消失
    final list = tester.widget<ListView>(find.byType(ListView));
    list.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('line 0 -----------------------------------------------'),
        findsOneWidget);
    expect(find.text('line 499 -----------------------------------------------'),
        findsNothing);
    expect(tester.takeException(), isNull);

    // 追加行后自动回到底部（先滚回底部，重新激活贴底）
    list.controller!.jumpTo(100000);
    await tester.pumpAndSettle();
    log.add('tail line');
    log.flush();
    await tester.pumpAndSettle();
    expect(find.text('tail line'), findsOneWidget);
    expect(tester.takeException(), isNull);

    log.close();
  });
}
