import 'package:flutter/material.dart';

/// ZipStreams brand colours, taken from the Android TV app.
abstract final class ZipColors {
  static const background = Color(0xFF1A202C);
  static const surface = Color(0xFF2D3748);
  static const surfaceHigh = Color(0xFF3D4754);
  static const accent = Color(0xFF0EA5E9);
  static const accentAlt = Color(0xFF06B6D4);
  static const text = Color(0xFFE2E8F0);
  static const textSecondary = Color(0xFFCBD5E0);
  static const textMuted = Color(0xFF6B7280);
  static const live = Color(0xFF059669);
  static const offline = Color(0xFFEF4444);
  static const retrying = Color(0xFFF59E0B);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZipColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: ZipColors.accent,
    secondary: ZipColors.accentAlt,
    surface: ZipColors.background,
    onSurface: ZipColors.text,
    error: ZipColors.offline,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZipColors.background,
    dividerColor: ZipColors.surfaceHigh,
    dialogTheme: const DialogThemeData(backgroundColor: ZipColors.surface),
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: ZipColors.text,
      displayColor: ZipColors.text,
    ),
  );
}
