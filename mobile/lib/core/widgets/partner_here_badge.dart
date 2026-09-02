import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, kProfileMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/server_clock.dart';
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

/// The PARTNER's mood key, merged from two rails: the `mood` broadcast (the
/// instant one) and the presence row (the durable one). The face in every
/// AppBar watches this and nothing wider, so a mood landing rebuilds a 44pt
/// box and not the shell.
final partnerMoodProvider =
    StateNotifierProvider.autoDispose<PartnerMoodNotifier, String?>(
  PartnerMoodNotifier.new,
);

class PartnerMoodNotifier extends StateNotifier<String?> {
  PartnerMoodNotifier(this.ref)
      : super(
          PresenceService.mergeMood(
            ref.read(partnerPresenceProvider),
            PresenceService.moodHint.value,
          ),
        ) {
    // The database rail: the bind fetch, postgres_changes, the refetch on
    // resume, the 45s expiry — every row that arrives is re-merged.
    ref.listen(partnerPresenceProvider, (_, __) => _recompute());
    // The broadcast rail.
    PresenceService.moodHint.addListener(_recompute);
  }

  final Ref ref;

  void _recompute() {
    if (!mounted) return;
    state = PresenceService.mergeMood(
      ref.read(partnerPresenceProvider),
      PresenceService.moodHint.value,
    );
  }

  @override
  void dispose() {
    // moodHint is static and outlives this; a listener left on it is the
    // liveHint leak all over again.
    PresenceService.moodHint.removeListener(_recompute);
    super.dispose();
  }
}

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
  String? _channelTopic;
  String? _coupleId;

  void _subscribe() {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final myUid = ref.read(currentProfileProvider)?.id;

    // A DIFFERENT couple is binding, so what we are holding was broadcast by
    // somebody else's partner. This notifier is not autoDispose and nothing
    // invalidates it, while partnerPresenceProvider IS — so after an unlink and
    // a re-pair, or a sign-in as someone else on this handset, the badge took
    // `partnerScreen` from the previous relationship's broadcast and `fresh`
    // from the new partner's row, and said "<new partner> is on this screen
    // with you" on it. Broadcasts have no replay, so it stood until the new
    // partner next navigated — minutes, on a phone left open.
    //
    // Only on a real change of couple, never on the null returned above: the
    // couple reads null on every resume, and clearing on that would blank a
    // partner who has not moved. It cannot be driven from
    // SessionNotifier.endCouple with the other holders either — that notifier
    // has no ref, and reaching this provider from sessionProvider's own would
    // be a dependency cycle.
    if (_coupleId != null && _coupleId != couple.id) state = null;

    // Fully remove the old channel before recreating (no joined-but-dead
    // dupes). Not awaited — this runs as a listener on realtimeResumed and on
    // the couple, both of which want a void callback — but never swallowed: a
    // removal that keeps failing leaves the previous couple's channel joined
    // and still delivering their screens here, which is the thing above.
    final old = _channel;
    final oldTopic = _channelTopic;
    _channel = null;
    if (old != null) unawaited(_removeChannel(old, oldTopic));

    _coupleId = couple.id;
    final topic = 'screen_presence:${couple.id}';
    _channelTopic = topic;
    final ch = SupabaseService.client.channel(topic, opts: const RealtimeChannelConfig(private: true));
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
        // Leaving and arriving, on the same rail as typing — so the avatar
        // moves in ~100ms instead of waiting on a database write and a
        // postgres_changes hop, which is what made it linger. The DB write
        // still happens and is still the source of truth; this only stops the
        // screen waiting for it.
        .onBroadcast(
          event: 'live',
          callback: (payload) {
            if (payload['from'] == myUid) return; // our own echo
            final online = payload['online'];
            final atRaw = payload['at'];
            if (online is! bool || atRaw is! String) return;
            final at = DateTime.tryParse(atRaw);
            // The sender's clock, not ours: it orders the sender's own events,
            // which is all that is needed to reject a reordered broadcast.
            if (at == null) return;
            // Capped at now, though: the hint stream is shared with the
            // presence events below, which are stamped by OUR ServerClock. A
            // sender clock running ahead would otherwise leave a hint from the
            // future that a real, server-observed leave could never supersede.
            var stamped = at.toUtc();
            final now = ServerClock.now();
            if (stamped.isAfter(now)) stamped = now;
            PresenceService.applyLiveHint(online: online, at: stamped);
          },
        )
        // Their mood, the instant they choose it. The database write still
        // happens beside the broadcast and still decides; this only stops the
        // partner's face waiting ~1s on a postgres_changes hop to change.
        .onBroadcast(event: 'mood', callback: onMoodBroadcast)
        // The rails above all need the OTHER phone to still be running Dart.
        // An instant swipe-kill runs none — the only thing that outlives it is
        // the socket, which the OS closes as the process dies. Presence rides
        // exactly that: the server sees the close and emits the partner's
        // leave to this phone, no goodbye required from the dead app. The
        // other half is track()/untrack(), sent from wherever a person starts
        // or stops looking (main.dart's humanPresent flip) and re-sent on
        // every successful join below, because a rejoined channel starts
        // empty.
        .onPresenceJoin(
          (payload) {
            if (_fromPartner(
                payload.newPresences.map((p) => p.payload), myUid,)) {
              PresenceService.applyLiveHint(
                  online: true, at: ServerClock.now(),);
            }
          },
        )
        .onPresenceLeave(
          (payload) {
            if (_fromPartner(
                payload.leftPresences.map((p) => p.payload), myUid,)) {
              PresenceService.applyLiveHint(
                  online: false, at: ServerClock.now(),);
            }
          },
        )
        .subscribe((status, error) {
          // A newer _subscribe may have replaced this channel while the join
          // was in flight; its own callback will do the tracking.
          if (status == RealtimeSubscribeStatus.subscribed &&
              identical(_channel, ch) &&
              PresenceService.humanPresent) {
            trackLive();
          }
        });
    _channel = ch;
  }

  /// True when any of [payloads] was tracked by the partner rather than by
  /// this phone. Tracks carry `{'uid': <sender>}`; an entry with no uid is
  /// unknown, and unknown must never move an avatar.
  bool _fromPartner(Iterable<Map<String, dynamic>> payloads, String? myUid) =>
      payloads.any((p) {
        final uid = p['uid'];
        return uid is String && myUid != null && uid != myUid;
      });

  /// Claim liveness on the channel, so the SERVER can announce this phone's
  /// death for it. Idempotent — phoenix replaces the previous track for the
  /// same socket. Failures are logged, never swallowed: a track that never
  /// lands looks exactly like a partner who never arrives.
  void trackLive() {
    final myUid = ref.read(currentProfileProvider)?.id;
    final ch = _channel;
    if (ch == null || myUid == null) return;
    unawaited(ch.track({'uid': myUid}).then((r) {
      if (r != ChannelResponse.ok) debugPrint('[presence] track failed: $r');
    }).catchError((Object e) {
      debugPrint('[presence] track threw: $e');
    }),);
  }

  /// The person stopped looking (cover up, app backgrounded). The process and
  /// its socket can long outlive that moment, and a tracked socket with nobody
  /// behind it is the "process, not person" lie — so the claim is withdrawn
  /// explicitly rather than left to die with the process.
  void untrackLive() {
    final ch = _channel;
    if (ch == null) return;
    unawaited(ch.untrack().then((r) {
      if (r != ChannelResponse.ok) debugPrint('[presence] untrack failed: $r');
    }).catchError((Object e) {
      debugPrint('[presence] untrack threw: $e');
    }),);
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

  /// Tell the partner we arrived or left, immediately.
  ///
  /// Sent BESIDE the database write, never instead of it — if the socket is
  /// down this simply does nothing and the existing postgres_changes path still
  /// carries the change, a little slower. Failures are logged rather than
  /// swallowed: a broadcast that never leaves the device looks exactly like a
  /// partner who never moved.
  void announceLive({required bool online}) {
    final myUid = ref.read(currentProfileProvider)?.id;
    final ch = _channel;
    if (ch == null || myUid == null) return;
    try {
      ch.sendBroadcastMessage(
        event: 'live',
        payload: {
          'from': myUid,
          'online': online,
          'at': DateTime.now().toUtc().toIso8601String(),
        },
      );
    } catch (e) {
      debugPrint('[presence] live broadcast failed (online=$online): $e');
    }
  }

  /// Tell the partner what mood was just chosen, immediately.
  ///
  /// Sent BESIDE the database write with the SAME [at], never instead of it:
  /// if the socket is down this does nothing and the postgres_changes path
  /// carries the change, a little slower. `sent` is server time and exists
  /// only so the receiving phone can measure the hop.
  void announceMood(String mood, {required DateTime at}) {
    final myUid = ref.read(currentProfileProvider)?.id;
    final ch = _channel;
    if (ch == null || myUid == null) return;
    try {
      ch.sendBroadcastMessage(
        event: 'mood',
        payload: {
          'from': myUid,
          'mood': mood,
          'at': at.toUtc().toIso8601String(),
          'sent': ServerClock.now().toIso8601String(),
        },
      );
    } catch (e) {
      debugPrint('[presence] mood broadcast failed ($mood): $e');
    }
  }

  /// The 'mood' event, applied SYNCHRONOUSLY — no timer, no debounce, no
  /// refetch in the way. Named and visible so the "instant" law can be
  /// exercised without a socket: call it, read the provider, no await.
  @visibleForTesting
  void onMoodBroadcast(Map<String, dynamic> payload) {
    final myUid = ref.read(currentProfileProvider)?.id;
    Diag.record(DiagArea.presence, 'presence_mood_recv', fields: {
      'has_from_key': payload.containsKey('from'),
      'from_is_self': payload['from'] == myUid,
      'has_mood': payload['mood'] is String,
      'has_at': payload['at'] is String,
    },);
    if (payload['from'] == myUid) return; // our own echo
    final mood = payload['mood'];
    final atRaw = payload['at'];
    if (mood is! String || mood.isEmpty || atRaw is! String) return;
    final at = DateTime.tryParse(atRaw)?.toUtc();
    if (at == null) return;
    if (kDebugMode || kProfileMode) {
      final sent = DateTime.tryParse(payload['sent'] as String? ?? '');
      final hop = sent == null
          ? null
          : ServerClock.now().difference(sent).inMilliseconds;
      debugPrint('[mood] recv $mood rail=bcast one_way_ms=$hop');
    }
    PresenceService.applyMoodHint(mood: mood, at: at);
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

  /// The topic is carried in rather than read back off the channel:
  /// `RealtimeChannel.topic` is package-internal, and naming the failing
  /// channel is the whole point of the log line.
  Future<void> _removeChannel(RealtimeChannel ch, String? topic) async {
    try {
      await SupabaseService.client.removeChannel(ch);
    } catch (e) {
      debugPrint('[presence] screen channel remove failed '
          '(${topic ?? 'unknown topic'}): $e');
    }
  }

  @override
  void dispose() {
    realtimeResumed.removeListener(_subscribe);
    final c = _channel;
    final t = _channelTopic;
    _channel = null;
    _channelTopic = null;
    if (c != null) unawaited(_removeChannel(c, t));
    super.dispose();
  }
}

/// Go to where they are. Tab screens select their tab; everything else is a
/// push, so Back returns the user to where they were.
///
/// Top-level and public because two presence surfaces now offer the same trip
/// — the AppBar badge and the standing figure — and a second copy of this
/// would be free to drift from the first.
void joinPartner(
  WidgetRef ref, {
  String? route,
  String? tab,
}) {
    // The router comes from the provider, never from a BuildContext: the standing
    // figure is mounted in MaterialApp.router's `builder`, ABOVE the Router,
    // where GoRouter.of has no InheritedGoRouter to find — build 73 threw a
    // `_TypeError` on every tap of the figure (client_errors, 2026-09-01).
    // Same GoRouter instance main.dart passes as routerConfig.
    final router = ref.read(routerProvider);
    final here = router.state.uri.path;
    // Asked to go where we already are. Reachable in the moment before our own
    // screen has been published, and pushing would stack a second copy of the
    // page on top of itself.
    if (route == here) return;

    HapticFeedback.selectionClick();
    if (tab != null) {
      ref.read(shellTabProvider.notifier).state = tab;
      // Already inside the shell? Selecting the tab is the whole journey.
      if (here != '/app') router.go('/app');
      // A tab change is a setState, not a navigation, so the observer cannot
      // see it. Without this the user has moved and nobody has been told: their
      // partner keeps seeing the old tab, and this badge keeps offering a trip
      // they have already taken.
      presenceRouteObserver?.publishActiveTab();
      return;
    }
  if (route != null) router.push(route);
}
