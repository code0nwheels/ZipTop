import 'package:flutter/material.dart';

/// ZipStreams colours, matched to the streaming-platform web viewer
/// (`frontend/static/css/common/tokens.css`).
///
/// Video is watched in the dark, so this is one deliberately dark navy
/// palette with a single cobalt accent. Badges are tinted pills: a `*Dim`
/// fill with the matching `*Text` colour.
abstract final class ZipColors {
  // Surfaces, deepest first.
  static const page = Color(0xFF070C18);
  static const background = Color(0xFF0A1020); // --ground
  static const surface = Color(0xFF0E1628); // --raised
  static const hover = Color(0xFF17223A);
  static const surfaceHigh = Color(0xFF1F2C48); // --selected
  static const selected = surfaceHigh;

  // Hairlines.
  static const line = Color(0xFF1E2A42);
  static const lineHi = Color(0xFF2B3A57);

  // Text.
  static const text = Color(0xFFEAF0FA);
  static const textSecondary = Color(0xFFAEBBD3);
  static const textMuted = Color(0xFF8D9BB6);

  // The one accent.
  static const accent = Color(0xFF2F6BEA);
  static const accentHi = Color(0xFF2A62DD);
  static const onAccent = Color(0xFFFFFFFF);

  /// Accent used as text or an icon on navy; also favourites.
  static const accentText = Color(0xFF9DBBFF);
  static const accentAlt = accentText;
  static const focus = accentText;

  // Status.
  static const warn = Color(0xFFFF9447);
  static const danger = Color(0xFFFF6B5E);
  static const success = Color(0xFF5FD38D);
  static const info = Color(0xFF6CCFE0);
  static const live = success;
  static const offline = danger;
  static const retrying = warn;

  static const warnText = Color(0xFFFFB27D);
  static const dangerText = Color(0xFFFF9A90);
  static const successText = Color(0xFF8FE2B0);

  // Tinted fills.
  static const accentDim = Color(0x332F6BEA); // 20%
  static const accentTint = Color(0x242F6BEA); // 14%, ch-num chip
  static const warnDim = Color(0x24FF9447);
  static const dangerDim = Color(0x24FF6B5E);
  static const successDim = Color(0x245FD38D);
  static const infoDim = Color(0x246CCFE0);
  static const neutralDim = Color(0x14EAF0FA); // 8%

  // Flat navy overlays (no blur anywhere).
  static const overlayTuning = Color(0xE6070C18); // .9
  static const overlayPlayer = Color(0xDB070C18); // .86
  static const overlayModal = Color(0xC7070C18); // .78
  static const overlayPill = Color(0xB3070C18); // .7
  static const overlaySoft = Color(0x99070C18); // .6
}

abstract final class ZipRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double pill = 999;

  static const smAll = BorderRadius.all(Radius.circular(sm));
  static const mdAll = BorderRadius.all(Radius.circular(md));
  static const lgAll = BorderRadius.all(Radius.circular(lg));
  static const pillAll = BorderRadius.all(Radius.circular(pill));
}

abstract final class ZipSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;
}

abstract final class ZipMotion {
  static const fast = Duration(milliseconds: 150);
  static const curve = Curves.ease;
}

abstract final class ZipShadow {
  static const lg = [
    BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 16)),
  ];
  static const md = [
    BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

abstract final class ZipText {
  static const family = 'AtkinsonNext';
  static const monoFamily = 'AtkinsonMono';

  /// Anything read as a number (channel numbers, times, counts, the clock)
  /// uses the mono face with tabular figures.
  static TextStyle mono({
    double fontSize = 12.5,
    FontWeight fontWeight = FontWeight.w500,
    Color color = ZipColors.textMuted,
    double? height,
  }) =>
      TextStyle(
        fontFamily: monoFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Group labels such as "Categories" or "On now": sentence case, bold,
  /// quiet colour. No uppercase eyebrows.
  static const label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: ZipColors.textMuted,
  );
}

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: ZipColors.accent,
    onPrimary: ZipColors.onAccent,
    primaryContainer: ZipColors.accentDim,
    onPrimaryContainer: ZipColors.accentText,
    secondary: ZipColors.accentText,
    onSecondary: ZipColors.page,
    secondaryContainer: ZipColors.selected,
    onSecondaryContainer: ZipColors.text,
    tertiary: ZipColors.info,
    onTertiary: ZipColors.page,
    error: ZipColors.danger,
    onError: ZipColors.page,
    errorContainer: ZipColors.dangerDim,
    onErrorContainer: ZipColors.dangerText,
    surface: ZipColors.background,
    onSurface: ZipColors.text,
    onSurfaceVariant: ZipColors.textSecondary,
    surfaceDim: ZipColors.page,
    surfaceBright: ZipColors.hover,
    surfaceContainerLowest: ZipColors.page,
    surfaceContainerLow: ZipColors.background,
    surfaceContainer: ZipColors.surface,
    surfaceContainerHigh: ZipColors.surface,
    surfaceContainerHighest: ZipColors.hover,
    outline: ZipColors.lineHi,
    outlineVariant: ZipColors.line,
    shadow: Colors.black,
    scrim: ZipColors.overlayModal,
    inverseSurface: ZipColors.text,
    onInverseSurface: ZipColors.page,
    inversePrimary: ZipColors.accentText,
    surfaceTint: Colors.transparent,
  );

  final base = Typography.whiteMountainView.apply(
    fontFamily: ZipText.family,
    bodyColor: ZipColors.text,
    displayColor: ZipColors.text,
  );
  final textTheme = base.copyWith(
    headlineMedium: base.headlineMedium?.copyWith(
      fontSize: 34,
      height: 1.1,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
    ),
    headlineSmall: base.headlineSmall?.copyWith(
      fontSize: 26,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.26,
    ),
    titleLarge: base.titleLarge?.copyWith(
      fontSize: 22,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.22,
    ),
    titleMedium: base.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
    titleSmall: base.titleSmall?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    bodyLarge: base.bodyLarge?.copyWith(
      fontSize: 15,
      height: 1.5,
      letterSpacing: 0,
    ),
    bodyMedium: base.bodyMedium?.copyWith(
      fontSize: 14,
      height: 1.45,
      letterSpacing: 0,
    ),
    bodySmall: base.bodySmall?.copyWith(
      fontSize: 12.5,
      color: ZipColors.textSecondary,
      letterSpacing: 0,
    ),
    labelLarge: base.labelLarge?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    labelMedium: base.labelMedium?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: ZipColors.textMuted,
      letterSpacing: 0,
    ),
    labelSmall: base.labelSmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
  );

  WidgetStateProperty<Color?> overlay(Color hover) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return hover;
        if (states.contains(WidgetState.hovered)) return hover;
        if (states.contains(WidgetState.focused)) return hover;
        return null;
      });

  const pillShape = StadiumBorder();
  const focusSide = BorderSide(color: ZipColors.focus, width: 3);
  final buttonText = textTheme.labelLarge;

  OutlinedBorder pillWithFocus(Set<WidgetState> states) =>
      states.contains(WidgetState.focused)
          ? const StadiumBorder(side: focusSide)
          : pillShape;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: ZipText.family,
    textTheme: textTheme,
    scaffoldBackgroundColor: ZipColors.background,
    canvasColor: ZipColors.background,
    dividerColor: ZipColors.line,
    hoverColor: ZipColors.neutralDim,
    focusColor: ZipColors.accentDim,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    iconTheme: const IconThemeData(color: ZipColors.textSecondary),
    dividerTheme: const DividerThemeData(
      color: ZipColors.line,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.resolveWith(pillWithFocus),
        textStyle: WidgetStatePropertyAll(
          buttonText?.copyWith(fontWeight: FontWeight.w700),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return ZipColors.hover;
          if (s.contains(WidgetState.hovered) ||
              s.contains(WidgetState.pressed)) {
            return ZipColors.accentHi;
          }
          return ZipColors.accent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? ZipColors.textMuted
              : ZipColors.onAccent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        animationDuration: ZipMotion.fast,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.resolveWith(pillWithFocus),
        textStyle: WidgetStatePropertyAll(buttonText),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? ZipColors.textMuted
              : ZipColors.text,
        ),
        side: WidgetStateProperty.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.hovered)
                ? ZipColors.lineHi
                : ZipColors.line,
          ),
        ),
        overlayColor: overlay(ZipColors.hover),
        animationDuration: ZipMotion.fast,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.resolveWith(pillWithFocus),
        textStyle: WidgetStatePropertyAll(buttonText),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return ZipColors.textMuted;
          if (s.contains(WidgetState.hovered)) return ZipColors.text;
          return ZipColors.accentText;
        }),
        overlayColor: overlay(ZipColors.hover),
        animationDuration: ZipMotion.fast,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? const CircleBorder(side: focusSide)
              : const CircleBorder(),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return ZipColors.line;
          if (s.contains(WidgetState.selected)) return ZipColors.accentText;
          if (s.contains(WidgetState.hovered)) return ZipColors.text;
          return ZipColors.textSecondary;
        }),
        overlayColor: overlay(ZipColors.hover),
        animationDuration: ZipMotion.fast,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(side: BorderSide(color: ZipColors.line)),
      side: const BorderSide(color: ZipColors.line),
      backgroundColor: ZipColors.hover,
      selectedColor: ZipColors.accent,
      disabledColor: ZipColors.surface,
      checkmarkColor: ZipColors.onAccent,
      showCheckmark: false,
      labelStyle: WidgetStateTextStyle.resolveWith(
        (s) => TextStyle(
          fontFamily: ZipText.family,
          fontSize: 14,
          fontWeight: s.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w600,
          color: s.contains(WidgetState.selected)
              ? ZipColors.onAccent
              : ZipColors.textSecondary,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      elevation: 0,
      pressElevation: 0,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: ZipColors.hover,
      hoverColor: Colors.transparent,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      hintStyle: TextStyle(color: ZipColors.textMuted),
      prefixIconColor: ZipColors.textMuted,
      suffixIconColor: ZipColors.textMuted,
      border: OutlineInputBorder(
        borderRadius: ZipRadius.pillAll,
        borderSide: BorderSide(color: ZipColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: ZipRadius.pillAll,
        borderSide: BorderSide(color: ZipColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: ZipRadius.pillAll,
        borderSide: BorderSide(color: ZipColors.accent, width: 1.5),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: ZipColors.accentText,
      selectionColor: ZipColors.accentDim,
      selectionHandleColor: ZipColors.accent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZipColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: ZipRadius.lgAll,
        side: BorderSide(color: ZipColors.lineHi),
      ),
      barrierColor: ZipColors.overlayModal,
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: ZipColors.textSecondary,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: ZipColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: ZipRadius.mdAll,
        side: BorderSide(color: ZipColors.lineHi),
      ),
      menuPadding: const EdgeInsets.all(6),
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ZipColors.surface),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: ZipRadius.mdAll,
            side: BorderSide(color: ZipColors.lineHi),
          ),
        ),
        padding: WidgetStatePropertyAll(EdgeInsets.all(6)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: ZipColors.selected,
        borderRadius: ZipRadius.smAll,
        border: Border.all(color: ZipColors.lineHi),
      ),
      textStyle: const TextStyle(
        fontFamily: ZipText.family,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: ZipColors.text,
      ),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ZipColors.selected,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: ZipRadius.mdAll,
        side: BorderSide(color: ZipColors.lineHi),
      ),
      contentTextStyle: textTheme.bodyMedium,
      actionTextColor: ZipColors.accentText,
      width: 420,
    ),
    tabBarTheme: TabBarThemeData(
      indicatorColor: ZipColors.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: ZipColors.line,
      labelColor: ZipColors.text,
      unselectedLabelColor: ZipColors.textSecondary,
      labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle: textTheme.labelLarge,
      overlayColor: overlay(ZipColors.hover),
      splashFactory: NoSplash.splashFactory,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: ZipColors.accent,
      inactiveTrackColor: ZipColors.lineHi,
      thumbColor: ZipColors.text,
      overlayColor: ZipColors.accentDim,
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? ZipColors.onAccent
            : ZipColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? ZipColors.accent
            : ZipColors.hover,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? ZipColors.accent
            : ZipColors.lineHi,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? ZipColors.accent : null,
      ),
      side: const BorderSide(color: ZipColors.lineHi, width: 1.5),
      shape: const RoundedRectangleBorder(borderRadius: ZipRadius.smAll),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ZipColors.accent,
      linearTrackColor: ZipColors.line,
      circularTrackColor: ZipColors.line,
    ),
    listTileTheme: ListTileThemeData(
      shape: const RoundedRectangleBorder(borderRadius: ZipRadius.smAll),
      selectedTileColor: ZipColors.selected,
      selectedColor: ZipColors.text,
      iconColor: ZipColors.textSecondary,
      textColor: ZipColors.text,
      titleTextStyle: textTheme.bodyLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: textTheme.bodySmall,
    ),
    cardTheme: const CardThemeData(
      color: ZipColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: ZipRadius.mdAll,
        side: BorderSide(color: ZipColors.line),
      ),
    ),
    badgeTheme: const BadgeThemeData(
      backgroundColor: ZipColors.danger,
      textColor: ZipColors.page,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.hovered) ||
                s.contains(WidgetState.dragged)
            ? ZipColors.textMuted
            : ZipColors.lineHi,
      ),
      trackColor: const WidgetStatePropertyAll(ZipColors.surface),
      trackBorderColor: const WidgetStatePropertyAll(ZipColors.line),
      radius: const Radius.circular(ZipRadius.pill),
      thickness: const WidgetStatePropertyAll(6),
      crossAxisMargin: 2,
    ),
  );
}
