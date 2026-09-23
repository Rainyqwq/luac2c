// 主界面（防护）：左右双栏 —— 左栏操作区，右栏运行日志。
//
// 页面本身只做三件事：接住拖放文件、把用户操作转给 [PipelineCtl]、
// 把提示弹成 SnackBar。左栏的每一块都是 lib/home/ 下的独立部件。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home/actions_card.dart';
import 'home/login_strip.dart';
import 'home/mode_card.dart';
import 'home/source_card.dart';
import 'home/status_bar.dart';
import 'home/tools_card.dart';
import 'log_pane.dart';
import 'pipeline.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final PipelineCtl _ctl = PipelineCtl();
  static const MethodChannel _drop = MethodChannel('luac2c/drop');

  @override
  void initState() {
    super.initState();
    // 原生 runner 通过 WM_DROPFILES 把拖入的文件路径发到这个通道（支持多个）
    _drop.setMethodCallHandler((call) async {
      if (call.method == 'dropped') {
        final a = call.arguments;
        final paths = a is List
            ? a.map((e) => e.toString()).toList()
            : <String>[a.toString()];
        _ctl.addFiles(paths);
      }
      return null;
    });
    // 控制层不持有 BuildContext，提示由这里弹 SnackBar
    _ctl.onNotice = (m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating),
      );
    };
    _ctl.start();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 左右双栏：左栏操作区可滚动，右栏是整屏高度的运行日志。
    // 原先所有卡片排在一列里，固定高度的部分把窗口占满之后，日志那个
    // Expanded 只剩 0 高度 —— 这就是"终端显示不出来"的原因。
    // 只有左栏订阅流水线状态。日志面板只依赖 LogStore —— 若把它也包进
    // 同一个监听器，每完成一个文件都要把上千行日志重新排版一遍，
    // 这就是批量处理时界面发顿的主因。
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          final left = (box.maxWidth * 0.42).clamp(320.0, 460.0);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: left,
                  child: ListenableBuilder(
                    listenable: _ctl,
                    builder: (context, _) => SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const LoginStrip(),
                          const SizedBox(height: 12),
                          SourceCard(_ctl),
                          const SizedBox(height: 12),
                          ModeCard(_ctl),
                          const SizedBox(height: 12),
                          ToolsCard(_ctl),
                          const SizedBox(height: 12),
                          ActionsSection(_ctl),
                          const SizedBox(height: 10),
                          StatusBar(_ctl),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LogPane(
                    log: _ctl.log,
                    onCopied: _ctl.noteLogCopied,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
