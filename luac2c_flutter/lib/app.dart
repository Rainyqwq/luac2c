// 应用根组件：把主题状态接到 MaterialApp 上。
import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'theme.dart';

class Luac2cApp extends StatelessWidget {
  const Luac2cApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeCtl.I,
      builder: (context, _) => MaterialApp(
        title: 'luac2c For Windows',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Brightness.light, ThemeCtl.I.seed),
        darkTheme: AppTheme.build(Brightness.dark, ThemeCtl.I.seed),
        themeMode: ThemeCtl.I.dark ? ThemeMode.dark : ThemeMode.light,
        home: const AppShell(),
      ),
    );
  }
}
