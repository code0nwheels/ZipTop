import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/focus_ring.dart';

/// A titled card of setting rows, divided by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
  });

  final String? title;

  /// A quiet line under the card, for a note that covers every row.
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const Divider(height: 1, indent: 16, endIndent: 16));
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: ZipSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, ZipSpace.s2),
              child: Text(title!, style: ZipText.label),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: ZipColors.surface,
              borderRadius: ZipRadius.mdAll,
              border: Border.all(color: ZipColors.line),
            ),
            child: ClipRRect(
              borderRadius: ZipRadius.mdAll,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, ZipSpace.s2, 4, 0),
              child: Text(footer!, style: const TextStyle(fontSize: 12.5, color: ZipColors.textMuted)),
            ),
        ],
      ),
    );
  }
}

/// One setting: a title, an optional description and note, and its control
/// on the right.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.description,
    this.note,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.titleColor,
  });

  final String title;
  final String? description;

  /// A small caveat under the description, such as where it applies.
  final String? note;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final muted = !enabled;
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZipSpace.s4, vertical: 14),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: muted ? ZipColors.textMuted : (titleColor ?? ZipColors.text),
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    description!,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: muted ? ZipColors.textMuted : ZipColors.textSecondary,
                    ),
                  ),
                ],
                if (note != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.info_outline, size: 14, color: ZipColors.textMuted),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          note!,
                          style: const TextStyle(fontSize: 12.5, color: ZipColors.textMuted),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: ZipSpace.s5), trailing!],
        ],
      ),
    );
    if (onTap == null) return body;
    return ZipTappable(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.zero,
      hoverColor: ZipColors.hover,
      child: body,
    );
  }
}

/// A row with a switch; the whole row toggles it.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    this.description,
    this.note,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? description;
  final String? note;
  final bool value;

  /// Null disables the row.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return SettingsRow(
      title: title,
      description: description,
      note: note,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged(!value),
      trailing: ExcludeFocus(
        child: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}

/// A row with a drop-down choice.
class SettingsSelectRow<T> extends StatelessWidget {
  const SettingsSelectRow({
    super.key,
    required this.title,
    this.description,
    this.note,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.enabled = true,
  });

  final String title;
  final String? description;
  final String? note;
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: title,
      description: description,
      note: note,
      enabled: enabled,
      trailing: SettingsSelect<T>(
        values: values,
        selected: selected,
        label: label,
        onSelected: onSelected,
        enabled: enabled,
      ),
    );
  }
}

/// An outlined pill showing the current choice; opens a menu of [values].
class SettingsSelect<T> extends StatelessWidget {
  const SettingsSelect({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.enabled = true,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final value in values)
          MenuItemButton(
            onPressed: () => onSelected(value),
            leadingIcon: SizedBox(
              width: 18,
              child: value == selected
                  ? const Icon(Icons.check, size: 18, color: ZipColors.accentText)
                  : null,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: Text(
                label(value),
                style: TextStyle(
                  fontWeight: value == selected ? FontWeight.w700 : FontWeight.w500,
                  color: value == selected ? ZipColors.text : ZipColors.textSecondary,
                ),
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton(
        style: const ButtonStyle(
          padding: WidgetStatePropertyAll(EdgeInsets.fromLTRB(14, 8, 10, 8)),
          minimumSize: WidgetStatePropertyAll(Size(0, 36)),
        ),
        onPressed: !enabled
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label(selected)),
            const SizedBox(width: 6),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}

/// A read-only fact: a label on the left, its value on the right.
class SettingsFactRow extends StatelessWidget {
  const SettingsFactRow(this.label, this.value, {super.key, this.badge});

  final String label;
  final String value;

  /// Shown after the value, such as "12 days left".
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZipSpace.s4, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: ZipColors.textSecondary),
            ),
          ),
          if (badge != null) ...[badge!, const SizedBox(width: 10)],
          SelectableText(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// A grey bar standing in for text while it loads.
class SettingsPlaceholder extends StatelessWidget {
  const SettingsPlaceholder({super.key, this.width = 120, this.height = 12});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: const BoxDecoration(color: ZipColors.neutralDim, borderRadius: ZipRadius.smAll),
    );
  }
}
