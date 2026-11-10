import 'package:flutter/material.dart';

import '../theme.dart';
import 'focus_ring.dart';

/// A pill segmented group; the active segment is filled with the accent.
class SegmentedPills<T> extends StatelessWidget {
  const SegmentedPills({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.enabled,
  });

  final List<T> values;
  final T? selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  /// Segments this returns false for are shown dimmed and ignore taps.
  final bool Function(T)? enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ZipColors.background,
        borderRadius: ZipRadius.pillAll,
        border: Border.all(color: ZipColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in values)
            _Segment(
              text: label(v),
              active: v == selected,
              enabled: enabled?.call(v) ?? true,
              onTap: () => onSelected(v),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.text,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final String text;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active
        ? ZipColors.onAccent
        : enabled
            ? ZipColors.textSecondary
            : ZipColors.lineHi;
    return ZipTappable(
      onTap: enabled ? onTap : null,
      borderRadius: ZipRadius.pillAll,
      color: active ? ZipColors.accent : Colors.transparent,
      hoverColor: !enabled ? null : (active ? ZipColors.accentHi : ZipColors.hover),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}
