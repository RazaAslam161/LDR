I'll synthesize the spec directly. The three directions all share coral-on-deep-night DNA; I'll commit to a clear mood and graft the strongest ideas together.

# Miles — Design System: "Emberlight"

## 1. Mood
A wine-dark room at the end of the day, lit by one low flame: deep cocoa-plum surfaces dissolving into near-black, with warm coral embers and gilt pooling like candlelight on linen — everything glows rather than shines, breathes rather than blinks. We keep coral-on-deep-night as the anchor but pivot the night warm (cocoa-plum, not cold navy) and let a single starlit accent and slow ambient motion carry the "magical" note, so the app feels tender, sensual, and screenshot-worthy without ever going explicit.

**Tagline:** *Feel close, even from here.*

## 2. Color constants

```dart
// --- Scaffold / night ---
const kNight        = Color(0xFF120A0C); // app background base (warm plum near-black)
const kNightDeep    = Color(0xFF0A0506); // vignette edge / behind hero
const kSurface1     = Color(0xFF221017); // cards, sheets (plum tint)
const kSurface2     = Color(0xFF2F1620); // raised/pressed card, input fill (wine tint)
const kSurfaceGlass = Color(0xCC221017); // frosted nav/overlay fill (80% over blur)
const kHairline     = Color(0xFF3A2A30); // warm hairline base (use at 10–14% alpha)

// --- Accents ---
const kEmber        = Color(0xFFE8674A); // primary CTA, active glow
const kEmberSoft    = Color(0xFFF2956F); // gradient top, hover, halo, orb core
const kEmberDeep    = Color(0xFFD24A38); // gradient bottom, pressed
const kBlush        = Color(0xFFC84B6A); // hearts, Reach, breath-orb core rim
const kGilt         = Color(0xFFD9A86C); // hairlines, selected nav, tiny highlights
const kStar         = Color(0xFF8B7CF0); // celestial violet — twinkle, "same sky" tag

// --- Text ---
const kCream        = Color(0xFFFCEFE6); // text-primary (warm white)
const kTaupe        = Color(0xFFB8909A); // text-secondary (rose-taupe)
const kFaint        = Color(0xFF7A5560); // text-tertiary / disabled / hints

// --- Semantic ---
const kSage         = Color(0xFF8FB48A); // success / "in sync"
```

```dart
// --- Gradients ---
// Primary CTA fill (top-left → bottom-right, 135°)
const kCtaGradient = LinearGradient(
  begin: Alignment.topLeft, end: Alignment.bottomRight,
  colors: [kEmberSoft, kEmber, kEmberDeep], stops: [0.0, 0.55, 1.0],
);

// Ambient candle-glow (radial, full-screen background)
const kAmbientGradient = RadialGradient(
  center: Alignment(0.0, -0.18), radius: 1.15,
  colors: [Color(0xFF3A1622), Color(0xFF1C0A10), kNightDeep], stops: [0.0, 0.55, 1.0],
);

// Hero halo behind countdown (radial, additive feel)
const kHaloGradient = RadialGradient(
  center: Alignment(0.0, 0.05), radius: 0.9,
  colors: [Color(0x59F2956F), Color(0x00C84B6A)], stops: [0.0, 1.0], // ember@35% → blush@0%
);

// Breath-orb core (radial)
const kOrbGradient = RadialGradient(
  colors: [Color(0xFFF6C79A), kEmberSoft, Color(0x00C84B6A)], stops: [0.0, 0.5, 1.0],
);
```

## 3. Typography

`google_fonts`: **Fraunces** (display/headline/countdown — soft optical serif, lean into high contrast + slight negative tracking) and **Inter** (body/UI/labels — legible at small sizes; use Inter Tight for dense numerals if desired). Countdown digits use `FontFeature.tabularFigures()` so digits don't reflow.

```dart
TextTheme buildTextTheme() {
  final f = GoogleFonts.fraunces;
  final i = GoogleFonts.inter;
  return TextTheme(
    displayLarge:  f(fontSize: 56, fontWeight: FontWeight.w300, letterSpacing: -1.0, height: 1.04, color: kCream),
    displayMedium: f(fontSize: 40, fontWeight: FontWeight.w300, letterSpacing: -0.5, height: 1.06, color: kCream),
    displaySmall:  f(fontSize: 30, fontWeight: FontWeight.w400, letterSpacing: -0.25, height: 1.1, color: kCream),
    headlineLarge: f(fontSize: 26, fontWeight: FontWeight.w400, height: 1.15, color: kCream), // screen titles
    headlineMedium:f(fontSize: 22, fontWeight: FontWeight.w400, color: kCream),               // app bar title
    headlineSmall: f(fontSize: 20, fontWeight: FontWeight.w400, fontStyle: FontStyle.italic, color: kEmberSoft), // romantic accents ("3 sleeps to go")
    titleLarge:    i(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 0.1, color: kCream),
    titleMedium:   i(fontSize: 15, fontWeight: FontWeight.w600, color: kCream),
    titleSmall:    i(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: kTaupe), // eyebrows
    bodyLarge:     i(fontSize: 16, fontWeight: FontWeight.w400, letterSpacing: 0.1, height: 1.5, color: kCream),
    bodyMedium:    i(fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: 0.15, height: 1.5, color: kTaupe),
    labelLarge:    i(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: kCream), // buttons
    labelSmall:    i(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.4, color: kTaupe), // nav labels, timestamps
  );
}
```

Rules: headlines render in `kCream`, supporting copy in `kTaupe`. Sentence case everywhere (no ALL CAPS except optional eyebrow `titleSmall`). Countdown numerals = Fraunces `displayLarge` weight with `fontFeatures: [FontFeature.tabularFigures()]`.

## 4. Components

**FilledButton (primary):** pill `borderRadius: 28`, height 56, fill `kCtaGradient` (paint via `Ink`/`DecoratedBox` since `FilledButton` can't take a gradient directly — wrap a `Container(decoration: BoxDecoration(gradient: kCtaGradient))`). Label `labelLarge` in `kCream`. Resting glow: `BoxShadow(color: kEmber.withOpacity(0.35), blurRadius: 24, offset: Offset(0,6))`. 1px inner top highlight: `kGilt.withOpacity(0.12)`. Press = EmberPress.

**OutlinedButton (secondary):** transparent fill over surface, `border: Border.all(color: kGilt.withOpacity(0.30), width: 1)`, pill r28, label `kCream`. On press, border warms to `kEmber.withOpacity(0.60)` and a faint inner ember glow fades in.

**Card / surface:** `borderRadius: 24`, fill `kSurface1` with a top-lit gradient (`kSurface2` top → `kSurface1` bottom, fakes candlelight from above). Hairline `Border.all(color: kGilt.withOpacity(0.12), width: 1)`. Ambient shadow `BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 30, offset: Offset(0,12))`. Optional 4% film-grain overlay clipped to card. Hero/featured card adds a soft outer ember glow `kEmber.withOpacity(0.18)` blur 30 and GravityFloat.

**TextField / InputDecoration:** `filled: true, fillColor: kSurface2`, `borderRadius: 18`, no visible border at rest (`OutlineInputBorder(borderSide: BorderSide.none)`). Hint/label `kFaint`. On focus: 1.5px `kEmber` border + soft ember underglow (`kEmber.withOpacity(0.25)` blur 12 on the wrapping container), floating label tints `kGilt`. `cursorColor: kEmber`.

**NavigationBar (5 tabs):** floating frosted pill dock — inset 16px sides, 12px above safe area, `borderRadius: 28`, fill `kSurfaceGlass` over `BackdropFilter(ImageFilter.blur(sigmaX:18, sigmaY:18))`, top hairline `kGilt.withOpacity(0.12)`, height ~64. Icons: thin 1.5px line (Phosphor Light / Lucide), idle `kFaint`. No selection pill — light does the work (see GiltSelect). Center tab (Reach) is a slightly raised coral-glow "home star" node.

**AppBar:** fully transparent, `elevation: 0`, title `headlineMedium` cream left-aligned, no divider. Leading/trailing icons thin-line, `kGilt`-tinted. On scroll, fade in a faint bottom gradient scrim (`kNight` → transparent, ~24px) so content dissolves under it — never a solid bar.

**Iconography:** thin 1.5px line, rounded caps. Idle `kFaint`, active `kEmber`+`kGilt`. Hearts are the motif — soft-filled `kBlush` for Reach, outline elsewhere. **Dividers:** always `kGilt` @ 8–12% alpha; glow > border.

## 5. Motion language

Build these as named, reusable widgets. Defaults: ambient loops are GPU-cheap single `AnimationController`s; presses fire one light haptic (`HapticFeedback.lightImpact()`).

| Animation | Trigger | Duration / Curve | Effect |
|---|---|---|---|
| **EmberPress** | button/card tap | 90ms easeOut down, 220ms easeOutCubic settle | scale 1.0→0.96, glow blur 18→30, gradient +8% brightness; 1 light haptic |
| **CandleBreath** | idle, always-on | 7s easeInOut sine loop | ambient radial glow center drifts, scale pulses 1.0→1.06, hue shimmers ember↔rose |
| **FilmGrain** | idle, always-on | re-seed ~120ms (or 12-frame shader loop) | tiling grain @ 3–5% opacity, `BlendMode.overlay` |
| **DissolveIn** | page/route transition | 420ms easeOutCubic | new screen opacity 0→1 + slide up 16px; outgoing dims to 80% + blur 0→6px sigma |
| **StarfieldDrift** | idle ambient (sparse) | 60–120s linear wrap | ~40 faint stars on 2–3 parallax layers, per-star sine-twinkle 0.3↔1.0; keeps it "magical" without competing with the candle |
| **ShootingStarWish** | every 30–45s | 900ms easeOutCubic + 250ms tail | one coral streak arcs; tap → 6-twinkle burst (pure delight) |
| **OrbBreathe** | Breath Sync orb | 4s inhale easeInOutSine, 1s hold, 4s exhale | radius + bloom expand, orb-core warms at peak; two orbs (you + partner) drift into a shared ring when synced; optional sync haptic |
| **GiltSelect** | nav-icon select | 260ms easeOut + 500ms ring | icon outline→solid via gilt→ember tween, lifts 2px, one-shot light ring (opacity 0.5→0), label fades w400→w600 gilt |
| **ReachPulse** | Reach press-and-hold | ~850ms lub-dub loop; 600ms release bloom | heart scales 1.0→1.12 on heartbeat curve, ember bloom + ripple each beat; release = one bright bloom; partner's hold mirrors as offset rose ripple |
| **CountTick** | seconds digit change | 140ms cross-fade | old→new digit cross-fade + 2px vertical slip + momentary +12% glow on colon/seconds (tabular figures prevent reflow) |
| **FlickerWelcome** | Welcome load (once) | ~1.1s | wordmark + candle-glow "catch" flicker (opacity 0→1 with two 40ms dips, like a wick taking) |
| **GravityFloat** | hero cards / orb idle | 6s easeInOutSine | barely-perceptible 6px vertical float |

**Reusable widgets to create:** `AmbientBackground` (CandleBreath + StarfieldDrift + FilmGrain + ShootingStarWish in one Stack, sits behind every screen), `GlowButton` (gradient + glow + EmberPress), `AnimatedHeart` (ReachPulse), `AnimatedNavIcon` (GiltSelect), `BreathOrb` (OrbBreathe), `CountdownDigits` (CountTick + tabular figures), `DissolveRoute` (custom `PageRouteBuilder`), `GrainOverlay`, `FloatingDock` (frosted NavigationBar).

## 6. Flagship screens

**Welcome / Sign-in.** Open into a dark wine room: `AmbientBackground` fills the screen — warm ember pool at center (`#3A1622`) falling to near-black vignette, FilmGrain shimmering, a few StarfieldDrift stars high up. The Fraunces wordmark "Miles" sits high-center (`displayMedium`) and runs FlickerWelcome on load (wick catching). Beneath it one `bodyMedium` taupe line ("Feel close, even from here"). Composition is bottom-weighted: lots of dark negative space up top, eye drawn to the warm pool. Low in the frame, a frosted glass card holds two controls — a primary `GlowButton` ("Continue") whose resting glow breathes almost imperceptibly in sync with CandleBreath, and a ghost gilt-outline secondary ("I have a code") below. Focused input fields glow ember at the caret. Tapping Continue → DissolveIn.

**Countdown hero.** The emotional center. Against `AmbientBackground`, the time-until-visit renders in oversized Fraunces `displayLarge` cream numerals via `CountdownDigits`, stacked Days / Hours / Mins / Secs with hairline gilt labels beneath each. The seconds digit runs CountTick (soft 140ms cross-fade + glow flare; colon pulses faintly). Behind the cluster, `kHaloGradient` concentrates the room's light on the count, GravityFloating gently; a thin gilt progress arc wraps the cluster (journey from last visit → next), filling with `kCtaGradient` as the date nears — and as the visit approaches, the halo warms ember→gold and StarfieldDrift stars drift inward so the screen visibly *brightens*. Above the number, an eyebrow `titleSmall` ("Until we're together"); below, a `headlineSmall` italic line ("14 nights until Lisbon") and a low ember `GlowButton` ("Plan the visit"). Scrolling reveals candlelit memory cards that dissolve up under the app bar's gradient scrim.

**Bottom nav.** A `FloatingDock` — frosted wine pill (`kSurfaceGlass` + `BackdropFilter` sigma 18) hovering 16px above the safe area, single gilt top hairline — over the continuous AmbientBackground so the sky/candlelight never gets cut. Five thin-line icons in `kFaint`; the center Reach node sits slightly raised as a soft coral "home star." Tap fires GiltSelect: the icon warms outline→solid through a gilt→ember tween, lifts 2px, a soft ring of light blooms outward once and fades, its label fades in and thickens to w600 gilt while the previous icon cools back down. No hard pill or underline — light and warmth alone signal "you are here," and the whole bar breathes faintly with CandleBreath, like nav buttons catching the same low flame. Switching screens runs DissolveIn.