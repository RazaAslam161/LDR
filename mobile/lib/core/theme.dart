import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Miles design system — **"Emberlight"**.
///
/// A wine-dark room lit by one low flame: warm plum near-black surfaces,
/// coral embers and gilt that glow rather than shine. Dark-mode-first,
/// tender, sensual, magical — never explicit.
class MilesColors {
  MilesColors._();

  // ─── Night / surfaces (warm plum, not cold navy) ───────────────────
  static const night = Color(0xFF120A0C); // scaffold base
  static const nightDeep = Color(0xFF0A0506); // vignette edge / behind hero
  // Back-compat aliases (existing screens reference these names):
  static const navy950 = night;
  static const navy900 = Color(0xFF221017); // surface-1: cards, sheets
  static const navy800 = Color(0xFF2F1620); // surface-2: raised/input fill
  static const surface1 = Color(0xFF221017);
  static const surface2 = Color(0xFF2F1620);
  static const surfaceGlass = Color(0x99221017); // frosted nav/overlay over blur

  // ─── Text (warm) ───────────────────────────────────────────────────
  static const cream50 = Color(0xFFFCEFE6); // primary
  static const cream100 = Color(0xFFF3E3DA); // bright supporting
  static const cream200 = Color(0xFFEDE4D3);
  static const taupe = Color(0xFFB8909A); // secondary copy
  static const faint = Color(0xFF7A5560); // tertiary / hints / idle icons

  // ─── Accents ───────────────────────────────────────────────────────
  static const ember = Color(0xFFE8674A); // primary CTA, active glow
  static const emberSoft = Color(0xFFF2956F); // gradient top, halo, orb core
  static const emberDeep = Color(0xFFD24A38); // gradient bottom, pressed
  static const blush = Color(0xFFC84B6A); // hearts, Reach
  static const gilt = Color(0xFFD9A86C); // hairlines, selected nav, highlights
  static const star = Color(0xFF8B7CF0); // celestial violet — twinkle, "same sky"
  static const starlight = Color(0xFFFBEFD6); // sparkles / warm highlights
  static const sage = Color(0xFF8FB48A); // success / "in sync"

  // Back-compat accent aliases:
  static const coral400 = emberSoft;
  static const coral500 = ember;
  static const coral600 = emberDeep;
  static const emerald400 = sage;

  // ─── Glass / frosted surfaces ────────────────────────────────────
  // Dark scrims, not white tints. The app is a dark theme with light cream
  // text: a white veil at 10-16% over the animated backdrop LOWERED contrast
  // for that text and let the embers show through the middle of a paragraph.
  // Tinting toward `night` instead gives the text a stable, legible ground
  // while the blur still reads as glass at the edges.
  static const Color glass = Color(0x8C120A0C);
  static const Color glassStrong = Color(0xB8120A0C);
  static const Color glassSubtle = Color(0x59120A0C);
  static const Color glassBorder = Color(0x33E8C49A);
  static const Color glassEmber = Color(0x22E8784A);

  // Blur is the single most expensive thing this UI does — a BackdropFilter
  // forces the compositor to read back and blur everything behind it, and the
  // cost scales with sigma. These were 10/20/32; at 32 the panels also washed
  // out badly enough that content behind them competed with content on them.
  // Lower sigma reads as cleaner glass AND costs meaningfully less per frame on
  // the low-end phones this has to run on.
  static const double blurSm = 6.0;
  static const double blurMd = 12.0;
  static const double blurLg = 18.0;
  static const double blurXl = 48.0;

  static BoxDecoration glassDecoration({
    double radius = 18,
    Color? color,
    Color? borderColor,
    double borderWidth = 0.8,
  }) =>
      BoxDecoration(
        color: color ?? MilesColors.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ?? MilesColors.glassBorder,
          width: borderWidth,
        ),
      );
}

/// Named gradients for the Emberlight system.
class MilesGradients {
  MilesGradients._();

  /// Primary CTA fill (135°).
  static const cta = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [MilesColors.emberSoft, MilesColors.ember, MilesColors.emberDeep],
    stops: [0.0, 0.55, 1.0],
  );

  /// Full-screen ambient candle-glow.
  static const ambient = RadialGradient(
    center: Alignment(0, -0.18),
    radius: 1.15,
    colors: [Color(0xFF3A1622), Color(0xFF1C0A10), MilesColors.nightDeep],
    stops: [0.0, 0.55, 1.0],
  );

  /// Soft halo behind the countdown hero.
  static const halo = RadialGradient(
    center: Alignment(0, 0.05),
    radius: 0.9,
    colors: [Color(0x59F2956F), Color(0x00C84B6A)],
  );

  /// Breath-orb hot core.
  static const orb = RadialGradient(
    colors: [Color(0xFFF6C79A), MilesColors.emberSoft, Color(0x00C84B6A)],
    stops: [0.0, 0.5, 1.0],
  );
}

TextTheme _buildTextTheme() {
  TextStyle f(double size, FontWeight w,
          {double ls = 0, double h = 1.2, Color c = MilesColors.cream50, FontStyle? style}) =>
      GoogleFonts.fraunces(
          fontSize: size, fontWeight: w, letterSpacing: ls, height: h, color: c, fontStyle: style);
  TextStyle i(double size, FontWeight w,
          {double ls = 0, double h = 1.4, Color c = MilesColors.cream50}) =>
      GoogleFonts.inter(fontSize: size, fontWeight: w, letterSpacing: ls, height: h, color: c);

  return TextTheme(
    displayLarge: f(56, FontWeight.w300, ls: -1, h: 1.04),
    displayMedium: f(40, FontWeight.w300, ls: -0.5, h: 1.06),
    displaySmall: f(30, FontWeight.w400, ls: -0.25, h: 1.1),
    headlineLarge: f(26, FontWeight.w400, h: 1.15),
    headlineMedium: f(22, FontWeight.w400),
    headlineSmall: f(20, FontWeight.w400, c: MilesColors.emberSoft, style: FontStyle.italic),
    titleLarge: i(18, FontWeight.w600, ls: 0.1),
    titleMedium: i(15, FontWeight.w600),
    titleSmall: i(13, FontWeight.w600, ls: 0.4, c: MilesColors.taupe),
    bodyLarge: i(16, FontWeight.w400, ls: 0.1, h: 1.5),
    bodyMedium: i(14, FontWeight.w400, ls: 0.15, h: 1.5, c: MilesColors.taupe),
    labelLarge: i(14, FontWeight.w600, ls: 0.3),
    labelSmall: i(12, FontWeight.w500, ls: 0.4, c: MilesColors.taupe),
  );
}

ThemeData milesDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    // Transparent so the root EmberBackground (candle glow + embers) shows
    // through, and every glass surface has something warm to blur against.
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      surface: Colors.transparent,
      onSurface: MilesColors.cream50,
      primary: MilesColors.ember,
      onPrimary: MilesColors.cream50,
      secondary: MilesColors.blush,
      tertiary: MilesColors.gilt,
      outline: Color(0x33D9A86C),
      error: Color(0xFFE5736B),
    ),
    textTheme: _buildTextTheme(),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.fraunces(
        fontSize: 22,
        fontWeight: FontWeight.w400,
        color: MilesColors.cream50,
      ),
      iconTheme: const IconThemeData(color: MilesColors.gilt),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // Glass-tinted input fill — semi-transparent so blur reads through.
      fillColor: MilesColors.surface2.withValues(alpha: 0.5),
      hintStyle: const TextStyle(color: MilesColors.faint),
      labelStyle: const TextStyle(color: MilesColors.taupe),
      floatingLabelStyle: const TextStyle(color: MilesColors.gilt),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
            color: MilesColors.gilt.withValues(alpha: 0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
            color: MilesColors.gilt.withValues(alpha: 0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: MilesColors.ember, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: MilesColors.ember,
        foregroundColor: MilesColors.cream50,
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: MilesColors.cream50,
        minimumSize: const Size.fromHeight(56),
        side: BorderSide(color: MilesColors.gilt.withValues(alpha: 0.3)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: MilesColors.emberSoft),
    ),
    cardTheme: CardThemeData(
      // Glass card by default: semi-transparent so the ambient candle-glow
      // background reads through it.
      color: MilesColors.surface1.withValues(alpha: 0.7),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: MilesColors.gilt.withValues(alpha: 0.14)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      // Translucent so the frosted-glass blur reveals what's underneath.
      backgroundColor: MilesColors.night.withValues(alpha: 0.72),
      surfaceTintColor: Colors.transparent,
      indicatorColor: MilesColors.ember.withValues(alpha: 0.18),
      elevation: 0,
      height: 66,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => GoogleFonts.inter(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? MilesColors.gilt : MilesColors.faint,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? MilesColors.ember : MilesColors.faint,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: MilesColors.gilt.withValues(alpha: 0.1),
      thickness: 1,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: MilesColors.surface2.withValues(alpha: 0.9),
      contentTextStyle: const TextStyle(color: MilesColors.cream50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

/// Small helper so widgets can blur consistently (frosted glass).
ImageFilter milesBlur([double sigma = 18]) =>
    ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
