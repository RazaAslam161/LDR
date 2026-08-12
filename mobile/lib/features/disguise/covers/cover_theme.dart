import 'package:flutter/material.dart';

/// A Material theme scoped to a single cover screen.
///
/// The app's own theme is dark, custom-fonted and unmistakable. A cover that
/// inherits any of it — a dialog, a bottom sheet, a text-selection handle —
/// stops looking like a stock utility at the first tap, which is exactly the
/// two seconds the disguise has to survive.
///
/// Covers also must not use the platform font stack the rest of the app does:
/// a utility that ships with the phone renders in the system font, and a
/// downloaded typeface is a tell to anyone who has seen the OEM apps. Leaving
/// [ThemeData.textTheme] alone is what gets that for free.
ThemeData coverTheme({
  required Color primary,
  required Color surface,
  Brightness brightness = Brightness.light,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
    surface: surface,
  );
  // Opaque throughout, deliberately: these screens sit over nothing, and a
  // translucent panel is both an app-wide rule here and a thing no stock
  // utility does.
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      // Not a fill: this is how M3 is told to stop tinting the bar by
      // elevation, which is what makes it disagree with the body underneath.
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w500,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}
