import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/presence_route_observer.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/router.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The screen the LOCAL user is currently on, and the record of what was last
/// published about it. Written only by `PresenceRouteObserver`; drives the
/// "partner is here" comparison.
final myScreenProvider = StateProvider<String?>((ref) => null);

/// The PARTNER's current screen, kept in near-real-time via a broadcast channel
/// (`screen_presence:<coupleId>`) for sub-second sync. The durable presence DB
/// value (`current_screen`) is the fallback + freshness source.
final partnerScreenProvider =
    StateNotifierProvider<PartnerScreenNotifier, String?>(
  PartnerScreenNotifier.new,
);

/// Bumped every time either partner "warms the room" — a shared bloom that both
/// devices render at the same moment. It is a counter rather than a bool so a
/// second warmth while the first is still fading re-triggers the animation.
final roomWarmthProvider = StateProvider<int>((ref) => 0);

class PartnerScreenNotifier extends StateNotifier<String?> {
  PartnerScreenNotifier(this.ref) : super(null) {
    // Bind the moment the couple resolves, and rebind if it changes.
    ref.listen(currentCoupleProvider, (prev, next) {
      if (next?.id != _coupleId) _subscribe();
    }, fireImmediately: true,);
    // Rejoin on realtime reconnect (doze / network drop / resume).
    realtimeResumed.addListener(_subscribe);
  }

  final Ref ref;
  RealtimeChannel? _channel;
  String? _coupleId;

  void _subscribe() {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final myUid = ref.read(currentProfileProvider)?.id;

    // Fully remove the old channel before recreating (no joined-but-dead dupes).
    final old = _channel;
    _channel = null;
    if (old != null) {
      try {
        SupabaseService.client.removeChannel(old);
      } catch (_) {}
    }

    _coupleId = couple.id;
    final ch = SupabaseService.client.channel('screen_presence:${couple.id}');
    ch
        .onBroadcast(
          event: 'screen',
          callback: (payload) {
            // Recorded before the echo guard: "the broadcast never arrived" and
            // "it arrived shaped differently than announce() sent it" are the
            // same silence here, and the key names are what tell them apart.
            Diag.record(DiagArea.presence, 'presence_screen_recv', fields: {
              'has_from_key': payload.containsKey('from'),
              'has_screen_key': payload.containsKey('screen'),
              'keys_n': payload.length,
              'from_is_self': payload['from'] == myUid,
              'screen_null': payload['screen'] == null,
            },);
            if (payload['from'] == myUid) return; // ignore our own echo
            if (mounted) state = payload['screen'] as String?;
          },
        )
        .onBroadcast(
          event: 'warm',
          callback: (payload) {
            if (payload['from'] == myUid) return;
            if (mounted) ref.read(roomWarmthProvider.notifier).state++;
          },
        )
        .subscribe();
    _channel = ch;
  }

  /// Broadcast the local user's current screen to the partner instantly.
  void announce(String? screen) {
    final myUid = ref.read(currentProfileProvider)?.id;
    final ch = _channel;
    if (ch == null || myUid == null) return;
    try {
      ch.sendBroadcastMessage(
        event: 'screen',
        payload: {'from': myUid, 'screen': screen},
      );
    } catch (_) {}
  }

  /// Warm the room: a bloom that lands on BOTH screens at once.
  ///
  /// The local bump does not wait on the network, so the sender feels it even
  /// on a bad connection; the partner gets it over the same channel presence
  /// uses.
  void warm() {
    final now = DateTime.now();
    final last = _lastWarm;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 900)) {
      // A held finger should not machine-gun the partner's screen. Silent on
      // both ends — a haptic with no bloom reads as a broken button.
      return;
    }
    _lastWarm = now;
    HapticFeedback.mediumImpact();
    ref.read(roomWarmthProvider.notifier).state++;

    final myUid = ref.read(currentProfileProvider)?.id;
    final ch = _channel;
    if (ch == null || myUid == null) return;
    try {
      ch.sendBroadcastMessage(event: 'warm', payload: {'from': myUid});
    } catch (_) {}
  }

  DateTime? _lastWarm;

  @override
  void dispose() {
    realtimeResumed.removeListener(_subscribe);
    final c = _channel;
    if (c != null) {
      try {
        SupabaseService.client.removeChannel(c);
      } catch (_) {}
    }
    super.dispose();
  }
}

/// The partner's presence, as one small mark.
///
/// Lives in the AppBar of every room the two of them can share (see
/// [PartnerHereAction]). It shows in two cases, and stays silent otherwise:
///
///   * they are on THIS screen, and their presence is fresh (active within 45s)
///   * they are on another screen you are allowed to follow them into
///
/// Silence covers the rest — a stale heartbeat, or a room that is theirs alone.
/// It is deliberately easier for this widget to say nothing than to say
/// something wrong about where a real person is.
class PartnerHereBadge extends ConsumerWidget {
  const PartnerHereBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myScreen = ref.watch(myScreenProvider);
    final broadcastScreen = ref.watch(partnerScreenProvider);
    final dbPartner = ref.watch(partnerPresenceProvider);

    // Broadcast value is instant; the DB value is the durable fallback.
    final partnerScreen = broadcastScreen ?? dbPartner?.currentScreen;
    final fresh = dbPartner?.isTrulyOnline ?? false; // 45s freshness window

    final isHere =
        myScreen != null && myScreen != 'away' && partnerScreen == myScreen && fresh;

    final partnerName = ref.watch(
      partnerProfileProvider.select((p) => p?.displayName ?? 'Partner'),
    );

    // ── Texture (idea 3): the avatar carries their state, not just presence ──
    final typing = dbPartner?.isTyping ?? false;
    final mood = moodByKey(dbPartner?.currentMood);

    // Where tapping would take us. Null when they are somewhere private or
    // somewhere that is not a place — the avatar is then inert, not broken.
    final joinRoute = joinableRouteFor(partnerScreen);
    final joinTab = joinableTabIndex(partnerScreen);
    final canJoin = !isHere && fresh && (joinRoute != null || joinTab != null);

    // Two distinct states, one widget: WITH you (breathing, warm) or ELSEWHERE
    // but reachable (dimmer, tappable). Showing nothing when they are simply in
    // another room wastes the most useful signal the app has.
    final visible = isHere || canJoin;

    // Scaled away rather than unmounted, so it keeps its 44dp of the AppBar
    // whether or not anyone is there. Reserving the space costs a small gap on
    // a screen nobody is sharing; giving it up would shove the title sideways
    // every time a partner walks in or out, on every screen in the app.
    return AnimatedScale(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      scale: visible ? 1.0 : 0.0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: visible ? 1.0 : 0.0,
        // Material ancestor, not decoration: Text with no Material above it
        // falls back to Flutter's debug style, which is what underlined the
        // old version on every screen.
        child: Material(
          type: MaterialType.transparency,
          child: _PresenceAvatar(
            name: partnerName,
            isHere: isHere,
            typing: typing,
            moodColor: mood?.color,
            where: partnerScreen,
            // The loop is stopped while nothing is shown. Twenty-odd screens
            // now mount this, and a permanent 60fps rebuild on each of them —
            // for a partner who is usually offline — is exactly the kind of
            // invisible work the last perf pass went hunting for.
            active: visible,
            // One affordance, two meanings — both are "reach for them".
            // Together: warm the room, a bloom they feel on their screen too.
            // Apart: go to where they are. Inert otherwise, so a tap can never
            // land somewhere that does not exist.
            onTap: isHere
                ? () => ref.read(partnerScreenProvider.notifier).warm()
                : canJoin
                    ? () => _join(context, ref, route: joinRoute, tab: joinTab)
                    : null,
          ),
        ),
      ),
    );
  }

  /// Go to where they are. Tab screens select their tab; everything else is a
  /// push, so Back returns the user to where they were.
  void _join(
    BuildContext context,
    WidgetRef ref, {
    String? route,
    int? tab,
  }) {
    final here = GoRouter.of(context).state.uri.path;
    // Asked to go where we already are. Reachable in the moment before our own
    // screen has been published, and pushing would stack a second copy of the
    // page on top of itself.
    if (route == here) return;

    HapticFeedback.selectionClick();
    if (tab != null) {
      ref.read(shellTabProvider.notifier).state = tab;
      // Already inside the shell? Selecting the tab is the whole journey.
      if (here != '/app') context.go('/app');
      // A tab change is a setState, not a navigation, so the observer cannot
      // see it. Without this the user has moved and nobody has been told: their
      // partner keeps seeing the old tab, and this badge keeps offering a trip
      // they have already taken.
      presenceRouteObserver?.publishActiveTab();
      return;
    }
    if (route != null) context.push(route);
  }
}

/// Drop-in for an [AppBar.actions] list.
///
/// This is where presence belongs: beside the partner's name, in the screen's
/// own chrome. It previously floated top-centre over every screen — an overlay
/// that covered titles and buttons, appeared in the middle of whatever the user
/// was reading, and looked like a system alert rather than a person.
class PartnerHereAction extends StatelessWidget {
  const PartnerHereAction({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Center(child: PartnerHereBadge()),
      );
}

/// A small avatar that carries the partner's presence — where they are, what
/// they are doing, and a way to reach them.
///
/// Replaces the old "<name> is here" pill. That pill was a strip of text across
/// the top of every screen — it read as a system warning, obscured the AppBar,
/// and shouted a status that only ever needs to be felt. This says more with a
/// 30dp mark and no text at all, so it never widens, never wraps, and never
/// competes with the screen's own title:
///
/// * **breathing, warm, glowing** — they are on this screen with you
/// * **dimmer, with a slow orbit** — they are elsewhere; tap to go to them
/// * **quickened breath** — they are typing
/// * **their mood's colour** — carried in the gradient and the rings
/// * **an expanding ripple** — the moment they arrive where you are
class _PresenceAvatar extends StatefulWidget {
  const _PresenceAvatar({
    required this.name,
    required this.isHere,
    required this.typing,
    required this.moodColor,
    required this.where,
    required this.active,
    this.onTap,
  });

  final String name;
  final bool isHere;

  /// Whether anything is on screen. False stops the loop entirely.
  final bool active;
  final bool typing;
  final Color? moodColor;

  /// The room they are in, for the screen-reader label only.
  final String? where;

  final VoidCallback? onTap;

  @override
  State<_PresenceAvatar> createState() => _PresenceAvatarState();
}

class _PresenceAvatarState extends State<_PresenceAvatar>
    with TickerProviderStateMixin {
  /// One looping controller drives the breath, the orbit and the typing pulse.
  ///
  /// It repeats WITHOUT reverse so the same value can be read two ways: as a
  /// monotonic angle for the orbit, and — through a cosine — as a symmetric
  /// swell for the breath. A reversing controller would make the orbit swing
  /// back and forth like a broken clock.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _period,
  );

  /// Fires once when they arrive on this screen. Separate from the loop because
  /// it is a one-shot with its own curve, and it must be able to restart
  /// mid-flight if they step out and back in.
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  late final Listenable _repaint = Listenable.merge([_c, _arrive]);

  /// Typing quickens everything — the same tell as someone leaning forward.
  Duration get _period => Duration(milliseconds: widget.typing ? 1100 : 2600);

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
    if (widget.isHere) _arrive.forward(from: 0);
  }

  @override
  void didUpdateWidget(_PresenceAvatar old) {
    super.didUpdateWidget(old);
    if (widget.typing != old.typing) _c.duration = _period;
    if (widget.active != old.active || widget.typing != old.typing) {
      // repeat() resumes from the current value, so changing speed mid-breath
      // does not snap the ring.
      widget.active ? _c.repeat() : _c.stop();
    }
    if (widget.isHere && !old.isHere) _arrive.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    _arrive.dispose();
    super.dispose();
  }

  String get _initial {
    final n = widget.name.trim();
    return n.isEmpty ? '·' : n.characters.first.toUpperCase();
  }

  String get _semantics {
    if (widget.isHere) return '${widget.name} is on this screen with you';
    final where = widget.where;
    return where == null
        ? '${widget.name} is nearby'
        : '${widget.name} is in $where. Double tap to join them';
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.moodColor ?? MilesColors.blush;

    return Semantics(
      label: _semantics,
      button: widget.onTap != null,
      child: GestureDetector(
        onTap: widget.onTap,
        // A 30dp mark is below the 48dp touch minimum, so the gesture box is
        // padded out around it. Translucent (not opaque) so the surrounding
        // padding never eats a tap meant for whatever sits beneath.
        behavior: HitTestBehavior.translucent,
        child: SizedBox(
          width: 44,
          height: 44,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _repaint,
              builder: (context, child) {
                final turn = _c.value * 2 * math.pi;
                // cos → a symmetric 0→1→0 swell from a non-reversing loop.
                final breath = (1 - math.cos(turn)) / 2;
                final here = widget.isHere;

                return CustomPaint(
                  painter: _AuraPainter(
                    breath: breath,
                    turn: turn,
                    arrive: _arrive.value,
                    isHere: here,
                    tint: tint,
                  ),
                  child: Center(
                    child: Opacity(
                      // Elsewhere reads as further away, not as an error.
                      opacity: here ? 1 : 0.66,
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
                            color: MilesColors.cream50.withValues(
                              alpha: here ? 0.35 + breath * 0.35 : 0.28,
                            ),
                            width: 1.4,
                          ),
                          // The glow is the "with you" signal, so it is spent
                          // only there — a blurred shadow on every avatar on
                          // every screen is a lot of GPU for nothing.
                          boxShadow: here
                              ? [
                                  BoxShadow(
                                    color: tint.withValues(
                                      alpha: 0.25 + breath * 0.3,
                                    ),
                                    blurRadius: 8 + breath * 8,
                                    spreadRadius: breath * 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                );
              },
              // The glyph never changes, so it is built once instead of every
              // frame.
              child: Center(
                child: Text(
                  _initial,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    height: 1,
                    fontWeight: FontWeight.w600,
                    color: MilesColors.cream50,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Everything around the avatar disc: the arrival ripple and the orbit.
///
/// Painted rather than composed from widgets because both are pure strokes on
/// one canvas — nested AnimatedContainers would cost a layout pass every frame
/// to draw the same two circles.
class _AuraPainter extends CustomPainter {
  const _AuraPainter({
    required this.breath,
    required this.turn,
    required this.arrive,
    required this.isHere,
    required this.tint,
  });

  final double breath;
  final double turn;
  final double arrive;
  final bool isHere;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);

    // ── Arrival: two staggered rings pushing outward and fading. ──
    if (arrive > 0 && arrive < 1) {
      for (var i = 0; i < 2; i++) {
        final t = (arrive - i * 0.16).clamp(0.0, 1.0);
        if (t <= 0) continue;
        final e = Curves.easeOutCubic.transform(t);
        canvas.drawCircle(
          centre,
          15 + e * 7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8 * (1 - e)
            ..color = tint.withValues(alpha: 0.5 * (1 - e)),
        );
      }
    }

    // ── Elsewhere: a single arc orbiting the mark. ──
    if (!isHere) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: 18),
        turn,
        1.15,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.6
          ..color = tint.withValues(alpha: 0.28 + breath * 0.22),
      );
    }
  }

  @override
  bool shouldRepaint(_AuraPainter old) =>
      old.breath != breath ||
      old.turn != turn ||
      old.arrive != arrive ||
      old.isHere != isHere ||
      old.tint != tint;
}
