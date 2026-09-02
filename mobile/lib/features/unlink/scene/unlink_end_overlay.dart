import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:video_player/video_player.dart';

/// How a ceremony ends, seen for one breath over the whole app.
enum UnlinkEnding {
  /// The door opened from inside: warm light floods, then the app is back.
  relink,

  /// The lamp dies and the night takes the street: dark rises, then lifts on
  /// whatever screen comes next.
  ended,
}

/// The ritual's two endings, played ABOVE the router.
///
/// They cannot live in the ritual screen: both endings navigate, navigation
/// unmounts the screen mid-flight, and a farewell cut off halfway is worse
/// than none. So this sits in the root builder Stack beside WarmthOverlay,
/// survives every route change, and is triggered by one static notifier set
/// SYNCHRONOUSLY in the teardown path — the pinned sequence there gains no
/// await, because the wipe plays OVER the teardown, never instead of it.
///
/// WarmthOverlay's laws, all of them: IgnorePointer always (an ending must
/// never eat a tap), RepaintBoundary inside the Positioned slot (the
/// ParentDataWidget outage precedent), `SizedBox.shrink` the instant the
/// controller rests, and with animations off nothing plays at all — the
/// navigation IS the ending.
class UnlinkEndOverlay extends StatefulWidget {
  const UnlinkEndOverlay({super.key});

  /// Set it and walk away; the overlay consumes it. Null after every play.
  static final ValueNotifier<UnlinkEnding?> play =
      ValueNotifier<UnlinkEnding?>(null);

  /// Who was outside, for the film choice: the person who left is the person
  /// who walks back in (reunion) or away (parting). Set alongside [play] by
  /// the same synchronous teardown write; consumed with it. When null — an
  /// ending fired from a path that does not know, or a neutral-gender
  /// profile — the light-only ending plays, which is the pre-film behaviour
  /// and still a complete farewell.
  static final ValueNotifier<bool?> initiatorMale = ValueNotifier<bool?>(null);

  /// Whether anything is still owed to the screen.
  ///
  /// THE RULE THAT WAS MISSING. The light's envelope is 900ms; the reunion
  /// film is ten seconds. When the light completed, the status listener
  /// nulled the ending and the build collapsed the whole surface — film and
  /// all — which the owner saw as "appears for a second, then Home". And
  /// on a cold handset `initialize()` can outlast the light, so the surface
  /// could collapse before the film's FIRST frame: the earlier "never plays".
  /// Pure and static so the table of cases is a unit test, not a handset.
  @visibleForTesting
  static bool surfaceLives({
    required bool hasKind,
    required bool lightRunning,
    required bool hasFilm,
    required bool filmPending,
  }) =>
      hasKind && (lightRunning || hasFilm || filmPending);

  @override
  State<UnlinkEndOverlay> createState() => _UnlinkEndOverlayState();
}

class _UnlinkEndOverlayState extends State<UnlinkEndOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MilesMotion.floodOpen,
  );

  UnlinkEnding? _kind;
  VideoPlayerController? _film;

  /// A film has been asked for and has not yet finished or failed. Set
  /// SYNCHRONOUSLY with the ending, before `initialize()` is even awaited —
  /// the surface has to know a film is coming from the very first frame.
  bool _filmPending = false;

  @override
  void initState() {
    super.initState();
    UnlinkEndOverlay.play.addListener(_onPlay);
    _c.addStatusListener((status) {
      if (status != AnimationStatus.completed || !mounted) return;
      // The light is done. The ending is over only if nothing else is on
      // the surface or on its way to it.
      if (_film == null && !_filmPending) setState(() => _kind = null);
    });
  }

  void _onPlay() {
    final kind = UnlinkEndOverlay.play.value;
    if (kind == null) return;
    UnlinkEndOverlay.play.value = null; // consumed
    // The ending's voice plays even when its light cannot (animations off):
    // the door opening or the last latch, heard once, fire-and-forget.
    MilesSound.cue(kind == UnlinkEnding.relink ? Cue.unlock : Cue.seal);
    final male = UnlinkEndOverlay.initiatorMale.value;
    UnlinkEndOverlay.initiatorMale.value = null; // consumed with the ending
    if (!mounted || MilesMotion.off(context)) return;
    setState(() {
      _kind = kind;
      _filmPending = male != null;
    });
    _c
      ..duration = kind == UnlinkEnding.relink
          ? MilesMotion.floodOpen
          : MilesMotion.duskFall
      ..forward(from: 0);
    if (male != null) unawaited(_playFilm(kind, initiatorMale: male));
  }

  /// The film is gone — ended or failed. If the light has finished too, the
  /// surface has nothing left to show and folds.
  void _filmOver() {
    if (!mounted) return;
    setState(() {
      _film = null;
      _filmPending = false;
      if (!_c.isAnimating) _kind = null;
    });
  }

  /// The film, over the light. It rides the SAME IgnorePointer surface as the
  /// flood — an ending must never eat a tap, so the film cannot be skipped by
  /// touch and must never need to be: it releases itself at its final frame,
  /// and every failure path simply leaves the light ending, which was the
  /// whole farewell before films existed.
  Future<void> _playFilm(
    UnlinkEnding kind, {
    required bool initiatorMale,
  }) async {
    final path = kind == UnlinkEnding.relink
        ? FilmLibrary.reunion(initiatorMale: initiatorMale)
        : FilmLibrary.parting(initiatorMale: initiatorMale);
    final c = VideoPlayerController.asset(path);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_watchFilmEnd);
      await c.play();
      setState(() => _film = c);
    } catch (e) {
      debugPrint('ending film failed, the light plays alone: $e');
      unawaited(c.dispose().catchError((Object _) {}));
      // Nothing is coming any more; let the light's own end fold the
      // surface, or fold it now if the light already went.
      _filmOver();
    }
  }

  void _watchFilmEnd() {
    final c = _film;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.position >= c.value.duration && !c.value.isPlaying) {
      c.removeListener(_watchFilmEnd);
      unawaited(c.dispose().catchError((Object _) {}));
      _filmOver();
    }
  }

  @override
  void dispose() {
    UnlinkEndOverlay.play.removeListener(_onPlay);
    _film?.removeListener(_watchFilmEnd);
    _film?.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final kind = _kind;
            final film = _film;
            // The film outlives the light's short envelope; either alone —
            // or a film still on its way — keeps the surface mounted, and
            // all three gone collapses it. One predicate, tested as a table.
            if (!UnlinkEndOverlay.surfaceLives(
              hasKind: kind != null,
              lightRunning: _c.isAnimating,
              hasFilm: film != null,
              filmPending: _filmPending,
            )) {
              return const SizedBox.shrink();
            }
            if (kind == null) return const SizedBox.shrink();
            if (film != null && film.value.isInitialized) {
              return FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: film.value.size.width,
                  height: film.value.size.height,
                  child: VideoPlayer(film),
                ),
              );
            }
            if (!_c.isAnimating) return const SizedBox.shrink();
            final t = _c.value;
            // Swell fast, fade slow — the WarmthOverlay envelope, because an
            // ending is a breath, not a flash.
            final intensity = t < 0.25
                ? MilesMotion.enter.transform(t / 0.25)
                : 1 - MilesMotion.strike.transform((t - 0.25) / 0.75);
            return kind == UnlinkEnding.relink
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.2, 0.35),
                        radius: 1.4,
                        colors: [
                          MilesColors.starlight
                              .withValues(alpha: 0.75 * intensity),
                          MilesColors.gilt.withValues(alpha: 0.35 * intensity),
                          MilesColors.gilt.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  )
                : ColoredBox(
                    color: MilesColors.nightDeep
                        .withValues(alpha: 0.9 * intensity),
                  );
          },
        ),
      ),
    );
  }
}
