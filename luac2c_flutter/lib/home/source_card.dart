// 源文件卡片：批量文件列表 + 添加/示例/清空。
//
// 只读 [PipelineCtl] 的当前状态，所有写操作都回调给控制层。
//
// 列表的交互按 Windows 习惯来：双击是在资源管理器中定位，不是移除；
// 移除挂在行尾的 × 上，右键给完整菜单。这两点和手机上的列表正好相反。
import 'package:flutter/material.dart';

import '../pipeline.dart';
import '../widgets.dart';

class SourceCard extends StatelessWidget {
  final PipelineCtl ctl;
  const SourceCard(this.ctl, {super.key});

  @override
  Widget build(BuildContext context) {
    final files = ctl.files;
    final hasFiles = files.isNotEmpty;
    return AppCard(
      title: hasFiles ? '源文件（${files.length} 个）' : '源文件',
      icon: Icons.description_outlined,
      trailing: hasFiles
          ? TextButton(
              onPressed: ctl.busy ? null : ctl.clearFiles,
              child: const Text('全部移除'),
            )
          : null,
      children: [
        SizedBox(
          height: hasFiles ? 132 : 46,
          child: hasFiles ? _fileList(context) : _empty(),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Tooltip(
              message: '选择文件 (Ctrl+O)',
              child: OutlinedButton.icon(
                onPressed: ctl.busy ? null : ctl.pickFiles,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加文件（可多选）'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: '把项目 test 目录下的用例加进来',
            child: FilledButton.tonalIcon(
              onPressed:
                  ctl.busy ? null : () => ctl.addFiles(ctl.sampleFiles()),
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('加入示例脚本'),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _empty() {
    return Builder(builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('点击「添加文件」多选，或把多个 .lua 文件拖进窗口',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
      );
    });
  }

  /// 文件列表（带每个文件的通过/失败标记与移除按钮）
  Widget _fileList(BuildContext context) {
    return Builder(builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final files = ctl.files;
      return Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          itemCount: files.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: cs.outlineVariant),
          itemBuilder: (context, i) {
            final p = files[i];
            final name = p.split(r'\').last;
            final res = ctl.results[p];
            final c = res == null
                ? cs.onSurfaceVariant
                : res
                    ? cs.primary
                    : cs.error;
            // Windows 里双击文件名 = 去它所在的位置。放在这里能省掉
            // "打开输出目录"再自己找文件的步骤。
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: ctl.busy ? null : () => ctl.revealFile(p),
              onSecondaryTapDown: ctl.busy
                  ? null
                  : (d) => _rowMenu(context, p, d.globalPosition),
              child: ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(
                  res == null
                      ? Icons.description_outlined
                      : res
                          ? Icons.check_circle
                          : Icons.cancel,
                  size: 18,
                  color: c),
                title: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5)),
                subtitle: Text(p.substring(0, p.lastIndexOf(r'\')),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '移除',
                  onPressed: ctl.busy ? null : () => ctl.removeFileAt(i),
                ),
              ),
            );
          },
        ),
      );
    });
  }

  /// 行内右键菜单。给的是这个文件能做的全部动作，而不是只有一个"移除"。
  void _rowMenu(BuildContext context, String path, Offset pos) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy,
          overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem(
          value: 'reveal',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open_outlined, size: 18),
            title: Text('在资源管理器中定位'),
          ),
        ),
        PopupMenuItem(
          value: 'copy',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy_all, size: 18),
            title: Text('复制完整路径'),
          ),
        ),
      ],
    ).then((v) {
      if (v == 'reveal') ctl.revealFile(path);
      if (v == 'copy') ctl.copyPath(path);
    });
  }
}
