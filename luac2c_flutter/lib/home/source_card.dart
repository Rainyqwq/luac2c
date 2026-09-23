// 源文件卡片：批量文件列表 + 添加/示例/清空。
//
// 只读 [PipelineCtl] 的当前状态，所有写操作都回调给控制层。
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
          child: hasFiles ? _fileList() : _empty(),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: ctl.busy ? null : ctl.pickFiles,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加文件（可多选）'),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed:
                ctl.busy ? null : () => ctl.addFiles(ctl.sampleFiles()),
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('加入示例脚本'),
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
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('点击「添加文件」多选，或把多个 .lua 文件拖进窗口',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
      );
    });
  }

  /// 文件列表（带每个文件的通过/失败标记与移除按钮）
  Widget _fileList() {
    return Builder(builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final files = ctl.files;
      return Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
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
            return ListTile(
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
            );
          },
        ),
      );
    });
  }
}
