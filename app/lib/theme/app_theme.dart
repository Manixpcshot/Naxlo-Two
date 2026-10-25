import 'package:flutter/material.dart';

import 'palette.dart';

/// Material 3 theme, dark-first (a tunnel client lives in the tray, usually at
/// night). `black` is a separate mode for OLED laptops where ink0 saves power.
abstract final class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: Palette.violet, brightness: Brightness.light);
    return _base(
      scheme: scheme.copyWith(surface: Palette.paper, onSurface: Palette.inkOnPaper),
      brightness: Brightness.light,
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Palette.violet,
      brightness: Brightness.dark,
    ).copyWith(
      surface: Palette.ink1,
      onSurface: Palette.mist,
      primary: Palette.violet,
      secondary: Palette.cyan,
      error: Palette.rose,
    );
    return _base(scheme: scheme, brightness: Brightness.dark);
  }

  static ThemeData black() {
    final scheme = ColorScheme.fromSeed(
      seedColor: Palette.violet,
      brightness: Brightness.dark,
    ).copyWith(surface: Palette.ink0, onSurface: Palette.mist, primary: Palette.violet, secondary: Palette.cyan);
    return _base(scheme: scheme, brightness: Brightness.dark).copyWith(
      scaffoldBackgroundColor: Palette.ink0,
    );
  }

  static ThemeData _base({required ColorScheme scheme, required Brightness brightness}) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.dark ? Palette.ink0 : Palette.paper,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.comfortable,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      // No `cardTheme` here: that property's type was renamed across SDK
      // versions, and every surface in this app is a custom [Panel], so a global
      // Card theme would be dead configuration that only breaks on an SDK bump.
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ),
      dividerTheme: const DividerThemeData(thickness: 1, space: 1),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withOpacity(0.18),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurface.withOpacity(0.55)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withOpacity(0.18),
        height: 64,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(96, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(96, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark ? Palette.ink3 : Palette.paperRaised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      textTheme: Typography.englishLike2021.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
        decorationColor: scheme.onSurface,
      ),
    );
  }
}
