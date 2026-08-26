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

  /// The one destructive colour. Three copies of it lived as a literal in
  /// settings_screen — remove-partner, delete-account and the account row —
  /// which is how a fourth ends up a slightly different crimson.
  static const danger = Color(0xFFB83A57); // passionCrimson

  // Back-compat accent aliases:
  static const coral400 = emberSoft;
  static const coral500 = ember;
  static const coral600 = emberDeep;
  static const emerald400 = sage;

  // ─── Scrim + hairline ────────────────────────────────────────────
  // What is left of the frosted-glass set, renamed for what it actually does.
  // The rest of that vocabulary — glass, glassStrong, glassSubtle, glassEmber,
  // glassDecoration, four blur sigmas — described a look this app no longer
  // has, and a name is an invitation: leaving `glassDecoration()` in the theme
  // is how the next panel gets one.
  //
  // [scrim] is NOT decoration. It sits under a save button that overlays a
  // user's photo, where the icon has to stay legible against an image nobody
  // controls. Translucency is the requirement there, not the style.
  static const Color scrim = Color(0x8C120A0C);

  /// A one-pixel warm edge that separates a panel from what is behind it.
  static const Color hairline = Color(0x33E8C49A);

  /// The colour an [accent] wash of [alpha] settles to once it is resolved
  /// against the surface it sits on — opaque, and the same pixels the wash
  /// used to produce.
  ///
  /// Chips carry meaning in their tint: selected, live, error, this mood and
  /// not that one. Flattening them all to [surface2] would have thrown that
  /// away, but leaving them translucent meant the ember field animated
  /// through every badge on the screen. [over] defaults to the card fill
  /// because that is where chips live; pass [night] for one sitting directly
  /// on the scaffold.
  static Color tint(Color accent, double alpha, {Color over = surface1}) =>
      Color.alphaBlend(accent.withValues(alpha: alpha), over);
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
          {double ls = 0, double h = 1.2, Color c = MilesColors.cream50, FontStyle? style,}) =>
      GoogleFonts.fraunces(
          fontSize: size, fontWeight: w, letterSpacing: ls, height: h, color: c, fontStyle: style,);
  TextStyle i(double size, FontWeight w,
          {double ls = 0, double h = 1.4, Color c = MilesColors.cream50,}) =>
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
    // through where nothing is drawn over it. Panels themselves are opaque:
    // with the blur gone, a translucent card just let the animation run behind
    // the text.
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      // Opaque, and this one line is where three glassmorphism sweeps went
      // wrong. ColorScheme resolves surfaceContainerLow / surfaceContainer /
      // surfaceContainerHigh as `?? surface`, and those three are M3's
      // defaults behind a sheet, a menu and a dialog. While this was
      // transparent, every modal that named no colour of its own painted
      // nothing at all, and the ember field animated behind "Delete for
      // everyone" — nowhere near any dialog in the source, so no amount of
      // reading feature files could find it. A page gets its transparency
      // from scaffoldBackgroundColor below, which no modal reads.
      surface: MilesColors.night,
      // Named rather than left to `?? surface`, so a surface this theme has
      // no entry for — a date picker, a time picker, whatever M3 adds next —
      // lands on the panel colour instead of the page colour and reads as a
      // panel. Falling back to `night` would be opaque but flat against the
      // scaffold it floats over.
      surfaceContainerLowest: MilesColors.night,
      surfaceContainerLow: MilesColors.surface1,
      surfaceContainer: MilesColors.surface1,
      surfaceContainerHigh: MilesColors.surface1,
      surfaceContainerHighest: MilesColors.surface2,
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
      // Opaque. Half-transparent over a moving ember field meant the text you
      // were typing sat on top of an animation.
      fillColor: MilesColors.surface2,
      hintStyle: const TextStyle(color: MilesColors.faint),
      labelStyle: const TextStyle(color: MilesColors.taupe),
      floatingLabelStyle: const TextStyle(color: MilesColors.gilt),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
            color: MilesColors.gilt.withValues(alpha: 0.12),),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
            color: MilesColors.gilt.withValues(alpha: 0.12),),
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
      // Opaque by default. At 70% the candle-glow background animated through
      // every card, which is what glassmorphism looks like once the blur that
      // was smoothing it has been taken away.
      color: MilesColors.surface1,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: MilesColors.gilt.withValues(alpha: 0.14)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      // Opaque. At 72% over a moving ember field the bar shimmered while the
      // background animated beneath it, and the labels lost contrast on the
      // bright frames.
      backgroundColor: MilesColors.night,
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
    // Dialogs, sheets and menus. M3 gives each of these a fill from
    // colorScheme.surfaceContainer* and then blends `surfaceTint` into it in
    // proportion to elevation. Both halves of that default are the frosted
    // look this app keeps growing back: the fill was see-through, and the tint
    // is a second colour the palette never chose, applied by an implicit rule
    // that gets stronger the higher the surface floats. So each one names its
    // own fill and turns the tint off.
    dialogTheme: const DialogThemeData(
      backgroundColor: MilesColors.surface1,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: MilesColors.surface1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: MilesColors.surface2,
      surfaceTintColor: Colors.transparent,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(MilesColors.surface2),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(MilesColors.surface2),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: MilesColors.surface1,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: MilesColors.surface2,
      contentTextStyle: const TextStyle(color: MilesColors.cream50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
