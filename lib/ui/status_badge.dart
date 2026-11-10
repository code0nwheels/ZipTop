import 'package:flutter/material.dart';

import '../theme.dart';

enum BadgeTone { success, warn, danger, info, neutral, accent }

/// A tinted pill: a dim fill of the status hue with matching light text.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.label, {super.key, this.tone = BadgeTone.neutral, this.icon});

  final String label;
  final BadgeTone tone;
  final IconData? icon;

  static (Color fill, Color text) colors(BadgeTone tone) => switch (tone) {
        BadgeTone.success => (ZipColors.successDim, ZipColors.successText),
        BadgeTone.warn => (ZipColors.warnDim, ZipColors.warnText),
        BadgeTone.danger => (ZipColors.dangerDim, ZipColors.dangerText),
        BadgeTone.info => (ZipColors.infoDim, ZipColors.info),
        BadgeTone.neutral => (ZipColors.neutralDim, ZipColors.textSecondary),
        BadgeTone.accent => (ZipColors.accentDim, ZipColors.accentText),
      };

  @override
  Widget build(BuildContext context) {
    final (fill, fg) = colors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(color: fill, borderRadius: ZipRadius.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// A round icon on a tinted fill, for list leading slots.
class StatusIcon extends StatelessWidget {
  const StatusIcon(this.icon, {super.key, this.tone = BadgeTone.neutral, this.size = 36});

  final IconData icon;
  final BadgeTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (fill, fg) = StatusBadge.colors(tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: fg),
    );
  }
}
