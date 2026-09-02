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
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// Drop-in for an [AppBar.actions] list: the partner's face, beside the call
/// icon, wearing whatever mood they last chose.
///
/// Third design in a week, and the owner's own: "just shoulder and face, real
/// expressions, changes its mood according to the partner, instantly". The
/// first floated a badge over every screen; the second stood a full figure
/// breathing in the corner forever, and was rejected as an intrusion. This is
/// 44 points in the chrome, still when nobody is there, and alive — breath,
/// a blink, a glance — only while they are.
class PartnerHereAction extends StatelessWidget {
  const PartnerHereAction({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Center(child: _BustHost()),
      );
}

class _BustHost extends ConsumerStatefulWidget {
  const _BustHost();

  @override
  ConsumerState<_BustHost> createState() => _BustHostState();
}

class _BustHostState extends ConsumerState<_BustHost>
    with TickerProviderStateMixin {
  /// The breath and the glance, running ONLY while they are online. Repeats
  /// without reverse so a single value reads two ways — a cosine for the
  /// symmetric swell, a sine for the shift a quarter-turn behind it.
  late final AnimationController _loop;

  /// Fires once when they arrive on THIS screen. Starts settled, so an
  /// offline partner never owns a ticker.
  late final AnimationController _arrive;

  late final Listenable _repaint;

  bool _looping = false;
  bool _wasHere = false;

  /// Built HERE, not as lazy `late final` initialisers: with no partner this
  /// widget returns before it ever touches them, and dispose() would then
  /// RUN the initialiser on a deactivated element. The standing figure died
  /// of exactly this.
  @override
  void initState() {
    super.initState();
    _loop = AnimationController(vsync: this, duration: MilesMotion.breath);
    _arrive = AnimationController(
      vsync: this,
      duration: MilesMotion.reveal,
      value: 1,
    );
    _repaint = Listenable.merge([_loop, _arrive]);
  }

  /// Run after the frame, never during build: starting a ticker mid-build is
  /// how a widget starts throwing instead of breathing.
  void _sync({required bool fresh, required bool here, required bool off}) {
    if (!mounted) return;
    final shouldLoop = fresh && !off;
    if (shouldLoop != _looping) {
      _looping = shouldLoop;
      // repeat() resumes from the current value, so a partner who blinks
      // out and back does not snap the breath.
      shouldLoop ? _loop.repeat() : _loop.stop();
    }
    if (here && !_wasHere && !off) _arrive.forward(from: 0);
    _wasHere = here;
  }

  @override
  void dispose() {
    _loop.dispose();
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final partner = ref.watch(partnerProfileProvider);
    // No partner at all: nothing, not a placeholder. The old badge kept its
    // 44dp for this; a couple with nobody in it has nobody to keep it for.
    if (partner == null) return const SizedBox.shrink();

    final myScreen = ref.watch(myScreenProvider);
    final broadcastScreen = ref.watch(partnerScreenProvider);
    final fresh = ref.watch(
      partnerPresenceProvider.select((p) => p?.isTrulyOnline ?? false),
    );
    final dbScreen = ref.watch(
      partnerPresenceProvider.select((p) => p?.currentScreen),
    );
    // Broadcast value is instant; the DB value is the durable fallback.
    final partnerScreen = broadcastScreen ?? dbScreen;
    final isHere = myScreen != null &&
        myScreen != 'away' &&
        partnerScreen == myScreen &&
        fresh;
    final joinRoute = joinableRouteFor(partnerScreen);
    final joinTab = joinableTabIdentity(partnerScreen);
    final canJoin = !isHere && fresh && (joinRoute != null || joinTab != null);

    final name = partner.displayName;
    final variant = puppetVariantOf(partner.gender);
    final mood = moodByKey(ref.watch(partnerMoodProvider));
    final tint = mood?.color ?? MilesColors.ember;
    final off = MilesMotion.off(context);

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _sync(fresh: fresh, here: isHere, off: off),
    );

    // One affordance, two meanings — both are "reach for them". Together:
    // warm the room, a bloom they feel on their screen too. Apart: go to
    // where they are. Inert otherwise, so a tap can never land somewhere that
    // does not exist.
    final VoidCallback? onTap = isHere
        ? () => ref.read(partnerScreenProvider.notifier).warm()
        : canJoin
            ? () => joinPartner(ref, route: joinRoute, tab: joinTab)
            : null;

    // The face is the only visual carrier of the mood, so the label names it.
    final feeling = mood == null ? '' : ' is ${mood.label.toLowerCase()},';
    final label = isHere
        ? '$name$feeling here with you. Warm the room.'
        : canJoin
            ? '$name$feeling in $partnerScreen. Go to them.'
            : fresh
                ? '$name$feeling online.'
                : '$name$feeling away.';

    return Semantics(
      label: label,
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        // A 34dp figure is below the 48dp touch minimum, so the gesture box is
        // padded out around it. Translucent (not opaque) so the surrounding
        // padding never eats a tap meant for whatever sits beneath.
        behavior: HitTestBehavior.translucent,
        child: SizedBox(
          width: 44,
          height: 44,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _repaint,
              builder: (context, child) => CustomPaint(
                painter: _ArrivalRipple(
                  arrive: _arrive.value,
                  tint: tint,
                ),
                child: Center(
                  child: PresenceCharacter(
                    variant: variant,
                    size: 34,
                    disc: false,
                    mood: mood?.artName,
                    // At rest when they are away: a frozen mid-glance reads
                    // as a hang, and a loop stopped inside the blink window
                    // would hold their eyes shut for as long as they were gone.
                    turn: _looping ? _loop.value * 2 * math.pi : 0,
                    arrive: _arrive.value,
                    here: fresh,
                    tint: tint,
                    fallback: child!,
                  ),
                ),
              ),
              // The letter fallback — a genderless profile, or a failed
              // decode — never changes, so it is built once and handed down.
              child: _Initial(name: name, tint: tint, fresh: fresh),
            ),
          ),
        ),
      ),
    );
  }
}

/// The letter, in the small disc the badge always drew, for a profile that
/// has no face to wear.
class _Initial extends StatelessWidget {
  const _Initial({required this.name, required this.tint, required this.fresh});

  final String name;
  final Color tint;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final n = name.trim();
    final initial = n.isEmpty ? '·' : n.characters.first.toUpperCase();
    return Opacity(
      opacity: fresh ? 1 : 0.66,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tint, MilesColors.ember],
          ),
          border: Border.all(
            color: MilesColors.cream50.withValues(alpha: 0.3),
            width: 1.4,
          ),
        ),
        child: Center(
          child: Text(
            initial,
            style: MilesType.inter(
              fontSize: 13,
              height: 1,
              fontWeight: FontWeight.w600,
              color: MilesColors.cream50,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// Two rings that open out from the figure the moment they arrive where you
/// are, and are gone by the time the arrival has settled. Strokes on one
/// canvas — no `boxShadow`, no layout.
class _ArrivalRipple extends CustomPainter {
  const _ArrivalRipple({required this.arrive, required this.tint});

  final double arrive;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    if (arrive >= 1) return;
    final c = Offset(size.width / 2, size.height / 2);
    final t = MilesMotion.enter.transform(arrive.clamp(0.0, 1.0));
    for (final (delay, weight) in [(0.0, 1.0), (0.35, 0.6)]) {
      final u = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (u <= 0) continue;
      canvas.drawCircle(
        c,
        13 + 10 * u,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = tint.withValues(alpha: (1 - u) * 0.55 * weight),
      );
    }
  }

  @override
  bool shouldRepaint(_ArrivalRipple old) =>
      old.arrive != arrive || old.tint != tint;
}
