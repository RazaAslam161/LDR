import 'dart:ui';

/// A live camera filter: a 4×5 [ColorFilter.matrix] colour transform plus
/// optional blur, a blended colour overlay, and animated film grain.
///
/// IMPORTANT — matrix convention: Flutter's [ColorFilter.matrix] multiplies the
/// 0..255 R,G,B,A inputs by the 4×5 row-major matrix; the 5th value in each row
/// is a CONSTANT added in the SAME 0..255 scale. So an offset that should lift
/// pure black to RGB(25,20,30) is encoded as the constants (25, 20, 30) — NOT a
/// 0..1 fraction. The baked-image path (camera_bake.dart) applies the very same
/// matrix per-pixel, so a captured photo matches its live preview exactly.
class CameraFilter {
  const CameraFilter({
    required this.id,
    required this.label,
    required this.icon,
    required this.colorMatrix,
    this.blurSigma = 0.0,
    this.overlayColor,
    this.overlayBlendMode = BlendMode.srcOver,
    this.hasGrain = false,
    this.grainIntensity = 0.0,
  });

  final String id;
  final String label;
  final String icon;
  final List<double> colorMatrix; // 20 values, row-major 4×5
  final double blurSigma; // 0.0 = no blur
  final Color? overlayColor; // null = none
  final BlendMode overlayBlendMode;
  final bool hasGrain; // film grain overlay
  final double grainIntensity; // 0.0 .. 1.0
}

/// The ordered filter strip. Index 0 (Original) is the default.
const List<CameraFilter> kCameraFilters = [
  // ── 0. ORIGINAL (DEFAULT) — identity, no effect ──────────────────────────
  // First in the strip and selected on open, which is what every camera people
  // already know does. It is also the only setting that reaches the capture
  // fast path: with no filter and no mirror the sensor's own JPEG is sent
  // untouched, so there is nothing to decode, nothing to re-encode, and no
  // generation loss.
  CameraFilter(
    id: 'none',
    label: 'Original',
    icon: '⚪',
    colorMatrix: [
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      0, 0, 0, 1, 0, //
    ],
  ),

  // ── 1. FREESIA 🌸 ──────────────────────────────────────────────
  // Recreates the Snapchat "Freesia" lens look: soft warm rosy-mauve cast,
  // lifted blacks (faded film), reduced contrast, partial desaturation + grain.
  //
  // Step 1 — partial desaturation via luminosity mixing (rows sum to 1.0):
  //   R = 0.75·R + 0.15·G + 0.10·B
  //   G = 0.10·R + 0.78·G + 0.12·B
  //   B = 0.08·R + 0.12·G + 0.80·B
  // Step 2 — soft contrast: scale each row by 0.88/0.85/0.87 (pulls highlights
  //   down, compresses range):
  //   R: 0.88·[0.75,0.15,0.10] = [0.6600, 0.1320, 0.0880]
  //   G: 0.85·[0.10,0.78,0.12] = [0.0850, 0.6630, 0.1020]
  //   B: 0.87·[0.08,0.12,0.80] = [0.0696, 0.1044, 0.6960]
  // Step 3 — lifted blacks: constants chosen so black→RGB(25,20,30), a dark
  //   lavender-grey (0..255 scale). White then maps to ~(249,237,252): a soft
  //   warm lavender-pink highlight (toward mauve, NOT orange — B kept high).
  CameraFilter(
    id: 'freesia',
    label: 'Freesia',
    icon: '🌸',
    colorMatrix: [
      0.6600, 0.1320, 0.0880, 0, 25, //
      0.0850, 0.6630, 0.1020, 0, 20, //
      0.0696, 0.1044, 0.6960, 0, 30, //
      0, 0, 0, 1, 0, //
    ],
    hasGrain: true,
    grainIntensity: 0.18,
  ),

  // ── 2. NOIR 🖤 — true B&W, deep contrast ─────────────────────────────────
  // Desaturate via luminosity (0.299,0.587,0.114) on every channel, then boost
  // contrast ×1.15 with a −18 constant (≈ pivot around mid-grey: −0.15·128≈−19).
  //   row = 1.15·[0.299,0.587,0.114] = [0.34385, 0.67505, 0.13110]
  CameraFilter(
    id: 'noir',
    label: 'Noir',
    icon: '🖤',
    colorMatrix: [
      0.34385, 0.67505, 0.13110, 0, -18, //
      0.34385, 0.67505, 0.13110, 0, -18, //
      0.34385, 0.67505, 0.13110, 0, -18, //
      0, 0, 0, 1, 0, //
    ],
  ),

  // ── 3. WARM 🌅 — golden-hour shift ───────────────────────────────────────
  // R ×1.10 (+10 warm offset), G ×1.0, B ×0.88 (cool the blues).
  CameraFilter(
    id: 'warm',
    label: 'Warm',
    icon: '🌅',
    colorMatrix: [
      1.10, 0, 0, 0, 10, //
      0, 1.00, 0, 0, 0, //
      0, 0, 0.88, 0, 0, //
      0, 0, 0, 1, 0, //
    ],
  ),

  // ── 4. COOL 🧊 — toward cyan-blue ────────────────────────────────────────
  // B ×1.12 (+8), R ×0.88, slight cyan offset on G(+4)+B(+8).
  CameraFilter(
    id: 'cool',
    label: 'Cool',
    icon: '🧊',
    colorMatrix: [
      0.88, 0, 0, 0, 0, //
      0, 1.00, 0, 0, 4, //
      0, 0, 1.12, 0, 8, //
      0, 0, 0, 1, 0, //
    ],
  ),

  // ── 5. COLOR POP 🎨 (Vivid) — hard saturation punch ──────────────────────
  // Saturation matrix with s=1.35, lum (0.299,0.587,0.114): diag = lum·(1−s)+s,
  // off = lum·(1−s), (1−s) = −0.35. Rows sum to 1.0 (brightness preserved).
  //   R: [0.299·−0.35+1.35, 0.587·−0.35, 0.114·−0.35] = [1.24535,−0.20545,−0.03990]
  //   G: [−0.10465, 0.587·−0.35+1.35, −0.03990]       = [−0.10465, 1.14455,−0.03990]
  //   B: [−0.10465,−0.20545, 0.114·−0.35+1.35]        = [−0.10465,−0.20545, 1.31010]
  CameraFilter(
    id: 'color_pop',
    label: 'Vivid',
    icon: '🎨',
    colorMatrix: [
      1.24535, -0.20545, -0.03990, 0, 0, //
      -0.10465, 1.14455, -0.03990, 0, 0, //
      -0.10465, -0.20545, 1.31010, 0, 0, //
      0, 0, 0, 1, 0, //
    ],
  ),

  // ── 6. GOLDEN ✨ — warm amber, lifted shadows ────────────────────────────
  // Warm offset (+15 R, +8 G, −10 B in 0..255) + shadows lifted (+10 on R,G):
  //   R const = 15+10 = 25 ; G const = 8+10 = 18 ; B const = −10+10 = 0.
  // Slight diagonal pull (0.95/0.95/0.90) so highlights warm rather than blow.
  CameraFilter(
    id: 'golden',
    label: 'Golden',
    icon: '✨',
    colorMatrix: [
      0.95, 0, 0, 0, 25, //
      0, 0.95, 0, 0, 18, //
      0, 0, 0.90, 0, 0, //
      0, 0, 0, 1, 0, //
    ],
  ),

  // ── 7. RETRO 📷 — faded Polaroid ─────────────────────────────────────────
  // Lifted blacks (+20 all), reduced contrast (×0.80), yellow-green cast
  // (G +5, B −8): R const 20, G const 25, B const 12.
  CameraFilter(
    id: 'retro',
    label: 'Retro',
    icon: '📷',
    colorMatrix: [
      0.80, 0, 0, 0, 20, //
      0, 0.80, 0, 0, 25, //
      0, 0, 0.80, 0, 12, //
      0, 0, 0, 1, 0, //
    ],
    hasGrain: true,
    grainIntensity: 0.12,
  ),

  // ── 8. NEON 💜 — high-contrast magenta-cyan, deep blacks ─────────────────
  // R,B ×1.25, G ×0.80 (→ magenta highlights), negative constants crush blacks
  // (−20 R/B, −10 G). Plus a soft magenta SCREEN overlay.
  CameraFilter(
    id: 'neon',
    label: 'Neon',
    icon: '💜',
    colorMatrix: [
      1.25, 0, 0, 0, -20, //
      0, 0.80, 0, 0, -10, //
      0, 0, 1.25, 0, -20, //
      0, 0, 0, 1, 0, //
    ],
    overlayColor: Color(0x18FF00FF),
    overlayBlendMode: BlendMode.screen,
  ),

  // ── 9. SOFT 🤍 — portrait softening ──────────────────────────────────────
  // Gaussian blur σ2.5, brightness lift (+10 all), contrast ×0.92.
  CameraFilter(
    id: 'soft',
    label: 'Soft',
    icon: '🤍',
    colorMatrix: [
      0.92, 0, 0, 0, 10, //
      0, 0.92, 0, 0, 10, //
      0, 0, 0.92, 0, 10, //
      0, 0, 0, 1, 0, //
    ],
    blurSigma: 2.5,
  ),

  // ── 10. GLITCH ⚡ — channel-shift + scanline overlay ─────────────────────
  // R ×1.20, G ×0.85 (red push, green suppress). Red OVERLAY blend supplies the
  // scanline-ish tint.
  CameraFilter(
    id: 'glitch',
    label: 'Glitch',
    icon: '⚡',
    colorMatrix: [
      1.20, 0, 0, 0, 0, //
      0, 0.85, 0, 0, 0, //
      0, 0, 1.00, 0, 0, //
      0, 0, 0, 1, 0, //
    ],
    overlayColor: Color(0x22FF0044),
    overlayBlendMode: BlendMode.overlay,
  ),
];
