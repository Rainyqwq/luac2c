// 通用小组件：卡片外壳、标题行、等宽块、键值行、开关行、次按钮。
//
// 这些组件不依赖任何业务状态，主页与「我的」页都直接复用。
// 目的：把两页里重复了七八遍的 Card + Padding + Column 骨架收敛成一处，
// 以后调内边距、圆角、配色只改这里。
import 'package:flutter/material.dart';

/// 卡片内小标题
class SectionTitle extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 6),
      ],
      Text(text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: cs.primary,
              letterSpacing: 0.2)),
      const Spacer(),
      ?trailing,
    ]);
  }
}

/// 标准卡片：Card + Padding(16) + 纵向排列的内容。
///
/// 传了 [title] 就自动带一行 [SectionTitle]，省掉每个调用点重复写标题行。
class AppCard extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;
  final CrossAxisAlignment align;
  const AppCard(
      {super.key,
      this.title,
      this.icon,
      this.trailing,
      required this.children,
      this.align = CrossAxisAlignment.start});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: align,
          children: [
            if (title != null) ...[
              SectionTitle(title!, icon: icon, trailing: trailing),
              const SizedBox(height: 10),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 卡片正文里的「图标 + 标题」小头（比 SectionTitle 更重一点，用于段落开头）
class CardHeading extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const CardHeading(this.icon, this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 16, color: color ?? cs.primary),
      const SizedBox(width: 8),
      Text(text,
          style: TextStyle(
              fontSize: 13.5, fontWeight: FontWeight.w600, color: cs.onSurface)),
    ]);
  }
}

/// 灰底圆角等宽块：放指纹、命令、路径这类需要一眼看清的原文
class MonoBlock extends StatelessWidget {
  final String text;
  final double size;
  final double letterSpacing;
  final Color? color;
  final FontWeight weight;
  const MonoBlock(this.text,
      {super.key,
      this.size = 12,
      this.letterSpacing = 0,
      this.color,
      this.weight = FontWeight.normal});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: size,
            letterSpacing: letterSpacing,
            fontWeight: weight,
            color: color ?? cs.onSurfaceVariant),
      ),
    );
  }
}

/// 键值行：左侧固定宽度的标签，右侧可换行的值
class InfoRow extends StatelessWidget {
  final String keyText;
  final String value;
  final double keyWidth;
  final bool mono;
  const InfoRow(this.keyText, this.value,
      {super.key, this.keyWidth = 72, this.mono = true});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: keyWidth,
            child: Text(keyText,
                style: TextStyle(fontSize: 12, color: cs.primary))),
        Expanded(
          child: Text(value,
              style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: mono ? 'Consolas' : null,
                  color: cs.onSurface)),
        ),
      ]),
    );
  }
}

/// 带开关的设置行：图标 + 标题 + 说明 + Switch
class SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  const SwitchRow(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.value,
      required this.onChanged,
      this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 18, color: cs.onSurfaceVariant),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w500)),
            const SizedBox(height: 1),
            Text(subtitle,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
      Switch(value: value, onChanged: enabled ? onChanged : null),
    ]);
  }
}

/// 次操作按钮（带可选 Tooltip，文字过长自动省略）
class MinorButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? tip;
  const MinorButton(this.icon, this.label, this.onTap, {super.key, this.tip});

  @override
  Widget build(BuildContext context) {
    // 注意：OutlinedButton.icon 内部已经给 label 套了一层 Flexible，
    // 这里再套会触发 "Competing ParentDataWidgets"，长文字靠 ellipsis 收敛即可。
    final btn = OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12.5)),
    );
    return tip == null ? btn : Tooltip(message: tip, child: btn);
  }
}

/// 工具状态指示灯（M3：error / primary 容器配色）
class StatusDot extends StatelessWidget {
  final bool ok;
  final String label;
  final String path;
  const StatusDot(
      {super.key, required this.ok, required this.label, required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: path,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: ok ? cs.primaryContainer : cs.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok ? Icons.check_circle : Icons.error,
              size: 13, color: ok ? cs.onPrimaryContainer : cs.onErrorContainer),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: ok ? cs.onPrimaryContainer : cs.onErrorContainer)),
        ]),
      ),
    );
  }
}
