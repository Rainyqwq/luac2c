// 主题：明暗 + 种子色的持久化状态，以及 Material You 主题构建。
//
// 与业务无关，单独成模块，方便 AppShell / App 直接引用。
import 'dart:io';

import 'package:flutter/material.dart';

// ---------------------------------------------------------------- 主题控制
/// 明暗 + 种子色状态（持久化到 exe 同目录的 client_prefs.txt）
class ThemeCtl extends ChangeNotifier {
  ThemeCtl._();
  static final ThemeCtl I = ThemeCtl._();

  bool dark = false;
  int seedIndex = 0;

  /// Material You 的几套种子色（蓝 / 青 / 紫 / 绿 / 橙）
  static const seeds = <Color>[
    Color(0xFF00639B), // Blue（默认）
    Color(0xFF00696E), // Teal
    Color(0xFF6B4EFF), // Violet
    Color(0xFF386A20), // Green
    Color(0xFF984100), // Orange
  ];

  Color get seed => seeds[seedIndex];

  Future<void> load() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$exeDir\\client_prefs.txt');
      if (f.existsSync()) {
        final t = (await f.readAsString()).trim();
        for (final kv in t.split(';')) {
          final p = kv.split('=');
          if (p.length != 2) continue;
          if (p[0] == 'dark') dark = p[1] == '1';
          if (p[0] == 'seed') seedIndex = int.tryParse(p[1])?.clamp(0, 4) ?? 0;
        }
      }
    } catch (_) {/* 读取失败用默认值 */}
  }

  Future<void> _save() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      await File('$exeDir\\client_prefs.txt')
          .writeAsString('dark=${dark ? 1 : 0};seed=$seedIndex');
    } catch (_) {/* 写失败不影响运行 */}
  }

  Future<void> set(bool d) async {
    if (dark == d) return;
    dark = d;
    notifyListeners();
    await _save();
  }

  void toggle() => set(!dark);

  /// 切换 Material You 种子配色
  Future<void> cycleSeed() async {
    seedIndex = (seedIndex + 1) % seeds.length;
    notifyListeners();
    await _save();
  }
}

// ---------------------------------------------------------------- Material You 主题
class AppTheme {
  /// 由种子色生成完整 M3 配色方案（Material You 的核心：一套种子 → 整套角色色）
  static ColorScheme scheme(Brightness b, Color seed) =>
      ColorScheme.fromSeed(seedColor: seed, brightness: b);

  static ThemeData build(Brightness b, Color seed) {
    final cs = scheme(b, seed);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      // Windows 上保证中文正常显示
      fontFamily: 'Microsoft YaHei UI',
      visualDensity: VisualDensity.standard,
      // M3 动效规范：emphasized 减速曲线
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 3,
        backgroundColor: cs.surface,
        surfaceTintColor: cs.surfaceTint,
        foregroundColor: cs.onSurface,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surfaceContainerLow,
        surfaceTintColor: cs.surfaceTint,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: cs.outlineVariant, thickness: 1),
    );
  }
}
