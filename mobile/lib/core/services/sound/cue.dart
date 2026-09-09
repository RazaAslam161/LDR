import 'package:flutter/services.dart';

/// Which haptic fires WITH a cue. The haptic is synchronous and the sound is
/// not — on the low-end fleet a warm player still trails the finger by
/// 30–250ms, so the finger feels the moment and the sound arrives as its
/// tail. [none] is for call sites that already own a richer haptic (the
/// vibration patterns of TouchHaptics, the Reach buzz) — a cue must never
/// double-buzz them.
enum CueHaptic { none, selection, light, medium }

/// Every sound the app can make, each with its asset, its resting gain and
/// its paired haptic. The app authors no other audio.
///
/// Filenames are deliberately generic UI-sound vocabulary: `unzip -l` on the
/// APK lists every asset path in the clear, and nothing here may name what
/// the app is for.
///
/// PROVENANCE — all Pixabay (Content License, no attribution required),
/// mastered 2026-08-27 (mono ogg q3, loudnorm I=-23, trims/fades), then
/// transcoded 2026-09-08 to 48kHz AAC/.m4a for iOS - AVFoundation has no Ogg
/// Vorbis decoder, so every cue was silent there. Durations verified identical.
/// Ids are the cdn.pixabay.com/download/audio path stems:
///   tap        2026/04/13/audio_d451787531  "UI Tap Soft Short"
///   send       2026/05/17/audio_121c45dc66  "Quick short gust of wind"
///   receive    2026/03/01/audio_4182fd0ce7  "New Notification 040"
///   reach      2022/03/15/audio_70b06362a4  "singing bowl strike sound"
///   glow       2025/12/13/audio_eb701ed2f0  "Warm Pad Fragment – Short"
///   seal       2025/08/07/audio_5f5bfe7c84  "Button Press"
///   open       2024/12/20/audio_d3efed8c6c  "Magic Spell"
///   chime      2026/02/20/audio_547f040f5a  "Clear Bell Chime"
///   pulse      2026/06/10/audio_c9958ad5d0  "HeartBeat" (one lub extracted)
///   deal       2026/04/20/audio_b1b6cddcd6  "Taking playing card - 2"
///   unlock     2025/06/14/audio_c4db741135  "Cassette Recorder Stop Button"
///   wish       2022/03/15/audio_1380e7dd2c  "musical drips stylised" (one)
///   breath_in  2026/01/31/audio_d5fdcab56b  "Soft Wind" (4s rise slice)
///   breath_out same source, the slice reversed — the exhale IS the inhale
///   bed_air    2025/12/13/audio_044d82576f  "Deep Calm Texture – Short",
///              28s with a 2s tail-to-head acrossfade so the loop is seamless
enum Cue {
  /// A primary control acknowledging a touch. Played soft — it accompanies
  /// nearly every EmberPress, so it must murmur, not click.
  tap('assets/sound/tap.m4a', 0.5, CueHaptic.none),

  /// A message leaving. Fired at the optimistic paint, not the server ack —
  /// the sound belongs to the gesture, not the network.
  send('assets/sound/send.m4a', 0.8, CueHaptic.none),

  /// A message arriving while the chat is on screen.
  receive('assets/sound/receive.m4a', 0.8, CueHaptic.none),

  /// A Reach leaving your hand. The call site owns the medium haptic it
  /// already had; the bowl strike is the new half.
  reach('assets/sound/reach.m4a', 0.9, CueHaptic.none),

  /// The partner's warmth arriving (WarmthOverlay bloom).
  glow('assets/sound/glow.m4a', 0.8, CueHaptic.light),

  /// A capsule sealing.
  seal('assets/sound/seal.m4a', 0.85, CueHaptic.light),

  /// A capsule's open ceremony — the one long cue, spanning the reveal beat.
  open('assets/sound/open.m4a', 0.9, CueHaptic.medium),

  /// Generic quiet success: a ritual completed, a capsule already open.
  chime('assets/sound/chime.m4a', 0.7, CueHaptic.light),

  /// The partner's live pulse connecting (NOT per-beat: audio latency is
  /// variable and a lagging thump reads as a broken heart monitor — the
  /// per-beat channel stays haptic).
  pulse('assets/sound/pulse.m4a', 0.8, CueHaptic.none),

  /// A card dealt in the games.
  deal('assets/sound/deal.m4a', 0.6, CueHaptic.selection),

  /// The vault accepting its PIN.
  unlock('assets/sound/unlock.m4a', 0.7, CueHaptic.light),

  /// A wish dropped into the jar.
  wish('assets/sound/wish.m4a', 0.8, CueHaptic.light),

  /// Breath Sync phase swells — as long as the phases themselves.
  breathIn('assets/sound/breath_in.m4a', 0.7, CueHaptic.none),
  breathOut('assets/sound/breath_out.m4a', 0.7, CueHaptic.none);

  const Cue(this.asset, this.gain, this.haptic);

  final String asset;
  final double gain;
  final CueHaptic haptic;

  /// The one ambient bed (Breath Sync). A path, not a Cue: it loops through
  /// the engine's dedicated loop channel, never the cue pool.
  static const String bedAsset = 'assets/sound/bed_air.m4a';

  Future<void> fireHaptic() => switch (haptic) {
        CueHaptic.none => Future<void>.value(),
        CueHaptic.selection => HapticFeedback.selectionClick(),
        CueHaptic.light => HapticFeedback.lightImpact(),
        CueHaptic.medium => HapticFeedback.mediumImpact(),
      };
}
