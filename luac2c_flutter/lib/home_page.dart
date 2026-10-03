// 主界面（防护）：左右双栏 —— 左栏操作区，右栏运行日志，顶部状态卡。
//
// 页面本身只做两件事：接住拖放文件、把用户操作转给 [PipelineCtl]。
// 左栏的每一块都是 lib/home/ 下的独立部件；顶部状态卡与它们同一套
// 形状语言（16px 圆角 + 16px 边距），所以是同一版式里的一块。
// 快捷键按 Windows 惯例配：Ctrl+O 添加文件、Ctrl+Enter 开始构建、
// Esc 停止。窄窗口下切成单栏（日志在上、操作在下），否则 800px 宽会把
// 日志压到看不见。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home/actions_card.dart';
import 'home/chal_card.dart';
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

  // 窄于此宽度就放弃双栏。1024 是 Windows 常见窗口宽度减去边框后的余量。
  static const double _twoPaneBreakpoint = 900;

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
    // 控制层不持有 BuildContext。原先这里挂 SnackBar 弹提示，但它从底部
    // 浮起来会压住状态条，而状态条当时还要滚动才看得见。现在提示直接写进
    // 固定在底边的状态栏，没有会挡视野的浮层。
    _ctl.start();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// 左栏的卡片序列。抽出来是为了窄窗时换顺序时只改一处。
  ///
  /// 状态栏不在这里 —— 它固定在窗口底边，不随内容滚动。
  List<Widget> _leftColumn(BuildContext context) => <Widget>[
        SourceCard(_ctl),
        const SizedBox(height: 12),
        ModeCard(_ctl),
        const SizedBox(height: 12),
        ChalCard(_ctl),
        const SizedBox(height: 12),
        ToolsCard(_ctl),
        const SizedBox(height: 12),
        ActionsSection(_ctl),
      ];

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        // Ctrl+O 是 Windows 打开文件的通用键
        SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _OpenFilesIntent(),
        // Ctrl+Enter 开始构建。F5 在这里是空的，留给"刷新工具链探测"
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            _RunIntent(),
        // Esc 停止。Windows 里 Esc 永远是"中止正在做的事"
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _ChalIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _StopIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenFilesIntent: CallbackAction<_OpenFilesIntent>(
            onInvoke: (_) {
              if (!_ctl.busy) _ctl.pickFiles();
              return null;
            },
          ),
          _RunIntent: CallbackAction<_RunIntent>(
            onInvoke: (_) {
              if (!_ctl.busy) _ctl.run(full: true);
              return null;
            },
          ),
          _StopIntent: CallbackAction<_StopIntent>(
            onInvoke: (_) {
              _ctl.stop();
              return null;
            },
          ),
          // Ctrl+R：向刚构建出的产物重新要一次应答。
          // Windows 里 F5 习惯是刷新，这里用 Ctrl+R，读起来是"重发一次"。
          _ChalIntent: CallbackAction<_ChalIntent>(
            onInvoke: (_) {
              if (!_ctl.busy) _ctl.fetchChalAnswer();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              // 状态条在内容区外面，不随内容滚动。做成一张圆角卡片，
              // 边距与圆角都和下面的 AppCard 一致（见 home/status_bar.dart）。
              // 放在标题栏正下方：底边那条太沉，而且贴着日志区像是日志的一部分。
              // 它订阅 ctl 的进度与提示 —— 所以单独一个 ListenableBuilder，
              // 状态变化不会重建下面的卡片区。
              ListenableBuilder(
                listenable: _ctl,
                builder: (context, _) => StatusBar(_ctl),
              ),
              Expanded(
                // 状态条已经吃掉顶部安全区，这里只管左右与底部，
                // 免得内容区与状态条之间多出一道缝。
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      // 左右双栏：左栏操作区可滚动，右栏是整屏高度的运行日志。
                      // 原先所有卡片排在一列里，固定高度的部分把窗口占满之后，
                      // 日志那个 Expanded 只剩 0 高度 —— 这就是"终端显示不出来"
                      // 的原因。
                      //
                      // 只有左栏订阅流水线状态。日志面板只依赖 LogStore —— 若
                      // 把它也包进同一个监听器，每完成一个文件都要把上千行日志
                      // 重新排版一遍，这就是批量处理时界面发顿的主因。
                      final wide = box.maxWidth >= _twoPaneBreakpoint;

                      final left = SizedBox(
                        width:
                            wide ? (box.maxWidth * 0.42).clamp(320.0, 460.0) : null,
                        child: ListenableBuilder(
                          listenable: _ctl,
                          builder: (context, _) => SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _leftColumn(context),
                            ),
                          ),
                        ),
                      );

                      final log = LogPane(
                        log: _ctl.log,
                        onCopied: _ctl.noteLogCopied,
                      );

                      if (!wide) {
                        // 窄窗：单栏纵向排。操作区在上、日志在下，给日志一个
                        // 最小高度，否则它会被上面的卡片压到看不见。
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Flexible(child: left),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: (box.maxHeight * 0.45).clamp(180.0, 420.0),
                                child: log,
                              ),
                            ],
                          ),
                        );
                      }

                      // 左边距 16 与上面状态条卡片对齐，两张卡在同一条竖线上
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            left,
                            const SizedBox(width: 12),
                            Expanded(child: log),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpenFilesIntent extends Intent {
  const _OpenFilesIntent();
}

class _RunIntent extends Intent {
  const _RunIntent();
}

class _StopIntent extends Intent {
  const _StopIntent();
}

class _ChalIntent extends Intent {
  const _ChalIntent();
}
