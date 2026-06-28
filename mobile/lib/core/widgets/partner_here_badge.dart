import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The screen the LOCAL user is currently on. Set by [reportScreen]; drives the
/// "partner is here" comparison.
final myScreenProvider = StateProvider<String?>((ref) => null);

/// The PARTNER's current screen, kept in near-real-time via a broadcast channel
/// (`screen_presence:<coupleId>`) for sub-second sync. The durable presence DB
/// value (`current_screen`) is the fallback + freshness source.
final partnerScreenProvider =
    StateNotifierProvider<PartnerScreenNotifier, String?>(
  (ref) => PartnerScreenNotifier(ref),
);

class PartnerScreenNotifier extends StateNotifier<String?> {
  PartnerScreenNotifier(this.ref) : super(null) {
    // Bind the moment the couple resolves, and rebind if it changes.
    ref.listen(currentCoupleProvider, (prev, next) {
      if (next?.id != _coupleId) _subscribe();
    }, fireImmediately: true);
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
    ch.onBroadcast(
      event: 'screen',
      callback: (payload) {
        if (payload['from'] == myUid) return; // ignore our own announcements
        if (mounted) state = payload['screen'] as String?;
      },
    ).subscribe();
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

/// A floating "Partner is here" badge — shown whenever the partner is on the
/// SAME screen as you AND their presence is fresh (active within 45s). Placed
/// ONCE, globally (see main.dart), so it works on every screen automatically:
/// every screen already reports its name via reportScreen, which now also
/// tracks [myScreenProvider] and broadcasts to [partnerScreenProvider].
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

    final isHere = myScreen != null &&
        myScreen != 'away' &&
        myScreen != 'Camera' && // a push action, not a shared screen
        partnerScreen == myScreen &&
        fresh;

    final partnerName = ref.watch(
      partnerProfileProvider.select((p) => p?.displayName ?? 'Partner'),
    );

    return IgnorePointer(
      ignoring: !isHere,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        offset: isHere ? Offset.zero : const Offset(0, -2),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: isHere ? 1.0 : 0.0,
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: MilesColors.sage.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: MilesColors.sage.withValues(alpha: 0.5),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: MilesColors.night.withValues(alpha: 0.4),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _PulsingDot(),
                const SizedBox(width: 6),
                Text(
                  '$partnerName is here',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: MilesColors.sage,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: MilesColors.sage,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: MilesColors.sage.withValues(alpha: 0.3 + _c.value * 0.5),
              blurRadius: 4 + _c.value * 4,
              spreadRadius: _c.value * 2,
            ),
          ],
        ),
      ),
    );
  }
}
