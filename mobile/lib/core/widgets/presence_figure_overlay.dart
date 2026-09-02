import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/realtime/presence_route_observer.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/mood.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/presence_figure.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The partner standing in the corner of every screen, mounted ONCE.
///
/// This is a sibling of the router in `main.dart`, not a widget inside any
/// screen — the same place `WarmthOverlay` and `LockScreen` live. That is the
/// whole design: they can arrive and leave without a single screen reflowing,
/// no screen has to know they exist, and adding a new screen cannot forget to
/// include them.
///
/// It reads the SAME derived state the AppBar badge read, from the same
/// providers, and owns none of it. Every realtime rail — the screen broadcast,
/// the presence row, the 45s freshness window — is untouched by this file.
class PresenceFigureOverlay extends ConsumerStatefulWidget {
  const PresenceFigureOverlay({super.key});

  /// Standing height. Small enough to live beside a nav bar without becoming
  /// the subject of every screen.
  static const figureHeight = 116.0;

  @override
  ConsumerState<PresenceFigureOverlay> createState() =>
      _PresenceFigureOverlayState();
}

class _PresenceFigureOverlayState extends ConsumerState<PresenceFigureOverlay>
    with TickerProviderStateMixin {
  /// The breath and weight shift, running ONLY while they are on stage.
  /// It repeats WITHOUT reverse so a single value can be read two ways — a
  /// cosine for the symmetric swell, a sine for the shift a quarter-turn
  /// behind it.
  late final AnimationController _loop;

  /// The walk in, played forward on arrival and REVERSED to walk back out.
  late final AnimationController _enter;

  late final Listenable _repaint;

  /// How long they stand there before leaving. A breath and a half: long
  /// enough to be seen and recognised, far too short to become furniture.
  static final Duration _hold = MilesMotion.breath * 0.6;

  Timer? _leaving;

  /// Null when nobody is on stage. Otherwise 'here' or 'away' — the REASON
  /// they are, so a knock fires when they walk into your screen but not each
  /// time they hop between two screens you are not on.
  String? _standing;
  String? _lastReason;

  /// Built HERE and not as lazy `late final` initialisers.
  ///
  /// A partner who is offline never makes this overlay visible, so the
  /// controllers were never read — and `dispose()` calling `_loop.dispose()`
  /// then RAN the initialiser, constructing an AnimationController on an
  /// already-deactivated element and throwing out of the widget tree's own
  /// teardown. The commonest state this widget is in was the one that broke it.
  /// Caught by the ported presence tests' three hide cases.
  @override
  void initState() {
    super.initState();
    _loop = AnimationController(vsync: this, duration: MilesMotion.breath);
    _enter = AnimationController(vsync: this, duration: MilesMotion.reveal);
    _repaint = Listenable.merge([_loop, _enter]);
  }

  @override
  void dispose() {
    _leaving?.cancel();
    _loop.dispose();
    _enter.dispose();
    super.dispose();
  }

  /// THE WHOLE POINT OF THIS WIDGET, REWRITTEN.
  ///
  /// It used to `_loop.repeat()` for as long as the partner was online — and
  /// with ten joinable routes that is nearly the whole time the app is open.
  /// A 116-point figure breathing forever in the corner of the eye is not
  /// presence, it is an interruption that never ends, and it was reported as
  /// exactly that. Presence is now an EVENT with a quiet residue: they walk
  /// in, they are seen, they walk out, and a still dot holds the fact.
  void _knock({required String? reason, required bool motionOff}) {
    // Scheduled during build and run AFTER the frame — by which time this
    // State can already be gone, and touching a disposed controller's ticker
    // throws out of the widget tree's own teardown. Caught by the ported
    // presence tests, whose hide cases unmount this in exactly that window.
    if (!mounted) return;
    if (reason == _lastReason) return;
    _lastReason = reason;

    if (reason == null) {
      _leaving?.cancel();
      _loop.stop();
      if (_standing != null) setState(() => _standing = null);
      return;
    }
    // Reduce-motion is owed the fact, not the performance: the dot says it
    // without anything crossing the screen.
    if (motionOff) return;

    _leaving?.cancel();
    setState(() => _standing = reason);
    _loop.repeat();
    _enter.forward(from: 0);
    _leaving = Timer(_hold + MilesMotion.reveal, _retire);
  }

  void _retire() {
    if (!mounted) return;
    _enter.reverse().whenComplete(() {
      if (!mounted) return;
      _loop.stop();
      setState(() => _standing = null);
    });
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UnlinkRow?>(
        valueListenable: UnlinkState.current,
        builder: (_, ceremony, __) {
          if (ceremony != null) {
            // Hidden is not enough: anything left running would spin behind
            // the scene for the ceremony's whole 24 hours.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _knock(reason: null, motionOff: true),
            );
            return const SizedBox.shrink();
          }
          return _stand(context);
        },
      );

  /// The figure never stands on a screen that owns the whole frame.
  ///
  /// During the unlink ceremony the partner is the SUBJECT of what is on
  /// screen — a doorstep they walked out of, a room they are sitting in.
  /// A second copy of them breathing in the corner of that scene is not
  /// presence, it is an intrusion into it, and it was the first thing the
  /// owner saw on the real handset. The rule is the class, not the case:
  /// a full-frame cinematic owns its frame, and this overlay stays out.
  Widget _stand(BuildContext context) {
    final myScreen = ref.watch(myScreenProvider);
    final broadcastScreen = ref.watch(partnerScreenProvider);
    final dbPartner = ref.watch(partnerPresenceProvider);

    final partnerScreen = broadcastScreen ?? dbPartner?.currentScreen;
    final fresh = dbPartner?.isTrulyOnline ?? false;
    final isHere = myScreen != null &&
        myScreen != 'away' &&
        partnerScreen == myScreen &&
        fresh;

    final joinRoute = joinableRouteFor(partnerScreen);
    final joinTab = joinableTabIdentity(partnerScreen);
    final canJoin = !isHere && fresh && (joinRoute != null || joinTab != null);
    final visible = isHere || canJoin;

    final variant = puppetVariantOf(
      ref.watch(partnerProfileProvider.select((p) => p?.gender)),
    );

    // 'here' and 'away' only — never the screen name. They hop between two
    // rooms you are not in; that is not an arrival, and knocking for it is
    // how an event turns back into a resident.
    final reason = !visible || variant == PuppetVariant.neutral
        ? null
        : (isHere ? 'here' : 'away');
    final motionOff = MilesMotion.off(context);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _knock(reason: reason, motionOff: motionOff),
    );

    // Nothing standing there is nothing painted — not a transparent figure
    // still costing a frame.
    if (reason == null) return const SizedBox.shrink();

    final name = ref.watch(
      partnerProfileProvider.select((p) => p?.displayName ?? 'Partner'),
    );
    final tint = moodByKey(dbPartner?.currentMood)?.color ?? MilesColors.ember;
    final onStage = _standing != null;

    void act() => isHere
        ? ref.read(partnerScreenProvider.notifier).warm()
        : joinPartner(ref, route: joinRoute, tab: joinTab);

    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        // Clear of the nav bar and the screen edge.
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: SafeArea(
          child: Semantics(
            button: true,
            label: isHere
                ? '$name is here with you. Warm the room.'
                : '$name is elsewhere. Go to them.',
            child: GestureDetector(
              onTap: act,
              child: onStage
                  ? RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _repaint,
                        builder: (context, _) => PresenceFigure(
                          variant: variant,
                          height: PresenceFigureOverlay.figureHeight,
                          here: isHere,
                          turn: _loop.value * 2 * math.pi,
                          arrive: _enter.value,
                          tint: tint,
                        ),
                      ),
                    )
                  : _PresenceDot(here: isHere, tint: tint),
            ),
          ),
        ),
      ),
    );
  }
}

/// What is left when they have walked back out.
///
/// Eleven points, perfectly still, in their mood's colour: filled when they
/// are on this screen with you, an open ring when they are somewhere else.
/// The ring is the important half — "they are elsewhere" is a nudge to leave
/// the screen you chose, and a nudge has no business being loud. The 44-point
/// box around it is the tap target and nothing else; the old overlay claimed
/// a figure's worth of corner whether or not anyone was standing in it.
class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.here, required this.tint});

  final bool here;
  final Color tint;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: here ? tint : Colors.transparent,
              border: Border.all(
                color: tint.withValues(alpha: here ? 0.9 : 0.75),
                width: here ? 1 : 1.6,
              ),
            ),
          ),
        ),
      );
}
