import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/config.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/map_token.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


/// The full state of "who am I + who is my partner" used across the app.
class SessionState {
  const SessionState({
    this.loading = true,
    this.session,
    this.profile,
    this.couple,
    this.partner,
    this.partnerOnline = false,
    this.error,
  });

  final bool loading;
  final Session? session;
  final Profile? profile;
  final Couple? couple;
  final Profile? partner;
  final bool partnerOnline;
  final String? error;

  bool get isAuthenticated => session != null;
  bool get hasProfile => profile != null;
  bool get isLinked => couple != null;

  SessionState copyWith({
    bool? loading,
    Session? session,
    Profile? profile,
    Couple? couple,
    Profile? partner,
    bool? partnerOnline,
    String? error,
  }) {
    return SessionState(
      loading: loading ?? this.loading,
      session: session ?? this.session,
      profile: profile ?? this.profile,
      couple: couple ?? this.couple,
      partner: partner ?? this.partner,
      partnerOnline: partnerOnline ?? this.partnerOnline,
      error: error,
    );
  }
}

class SessionNotifier extends StateNotifier<SessionState> {
  SessionNotifier() : super(const SessionState());

  StreamSubscription<AuthState>? _authSub;
  RealtimeChannel? _presenceChannel;

  void init() {
    // Seed initial state from any stored session.
    final current = SupabaseService.client.auth.currentSession;
    state = SessionState(loading: false, session: current);

    _authSub = SupabaseService.authChanges.listen((event) async {
      state = state.copyWith(
        loading: false,
        session: event.session,
      );
      // A password-reset link opens a short-lived session and fires this. It
      // has to be surfaced, or the router's onboarding funnel sweeps the user
      // into the app and the reason they tapped the link never appears.
      if (event.event == AuthChangeEvent.passwordRecovery) {
        passwordRecovery.value = true;
      }
      if (event.session != null) {
        await loadProfile();
      }
    });

    if (current != null) {
      loadProfile();
    }
  }

  /// Keep the stored timezone matching the device.
  ///
  /// It was captured once during onboarding and never looked at again, so a
  /// user who travels — or who simply picked the wrong entry from the list —
  /// had a countdown and a partner clock that were quietly wrong forever, with
  /// no indication anything needed fixing. The device already knows; nobody
  /// should have to tell the app twice.
  Future<void> syncTimezone() async {
    final profile = state.profile;
    if (profile == null) return;
    try {
      final name = TzHelper.deviceZone(commonTimezones);
      if (name == profile.timezone) return;
      debugPrint('[tz] device=$name stored=${profile.timezone} — updating');
      await SupabaseRepository.updateMyProfile(timezone: name);
      await loadProfile();
    } catch (e) {
      debugPrint('[tz] sync failed: $e');
    }
  }

  Future<void> loadProfile() async {
    state = state.copyWith(loading: true);
    try {
      final profile = await SupabaseRepository.fetchMyProfile()
          .timeout(const Duration(seconds: 10));
      if (profile == null) {
        state = state.copyWith(loading: false);
        return;
      }

      Couple? couple;
      Profile? partner;
      if (profile.coupleId != null) {
        final coupleRes = await SupabaseService.client
            .from('couples')
            .select()
            .eq('id', profile.coupleId!)
            .maybeSingle()
            .timeout(const Duration(seconds: 10));
        if (coupleRes != null) {
          couple = Couple.fromJson(coupleRes);
          partner = await SupabaseRepository.fetchPartner(couple.id)
              .timeout(const Duration(seconds: 10));
        }
      }

      state = SessionState(
        loading: false,
        session: state.session,
        profile: profile,
        couple: couple,
        partner: partner,
      );

      // The couple every push on this handset is checked against. Written here
      // rather than at sign-in because pairing, leaving and re-pairing all
      // change it without a new session — and a stale value would either drop
      // this couple's pushes or admit the previous one's.
      unawaited(SessionScope.setCouple(couple?.id));

      if (couple == null) {
        // No couple (just left, or never paired): clear any stale presence
        // couple_id so a future partner can't inherit a dangling link. The DB
        // trigger + leave_couple() already handle this server-side; this is the
        // client-side belt-and-suspenders. Filtered with .not(is null) so we
        // only write when there's actually something to clear.
        try {
          final uid = SupabaseService.currentUserId;
          if (uid != null) {
            await SupabaseService.client
                .from('presence')
                .update({
                  'couple_id': null,
                  'is_online': false,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                })
                .eq('user_id', uid)
                .not('couple_id', 'is', null);
          }
        } catch (_) {}
        return; // No couple = nothing more to load.
      }

      final coupleId = couple.id;
      unawaited(_subscribePresence(coupleId));

      // PRESENCE INTEGRITY GUARD
      // Silently verify and repair presence.couple_id. Catches the case
      // where leave_couple + re-pair left presence pointing at the wrong
      // couple_id. Runs on every app load — a ~200ms read that prevents the
      // entire app from breaking. Never surfaces to the user: self-healing.
      try {
        final uid = SupabaseService.currentUserId;
        if (uid != null) {
          final row = await SupabaseService.client
              .from('presence')
              .select('couple_id')
              .eq('user_id', uid)
              .maybeSingle();
          if (row != null && row['couple_id'] != coupleId) {
            // Presence is stale — repair silently.
            await SupabaseService.client.from('presence').update({
              'couple_id': coupleId,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }).eq('user_id', uid);
          }
        }
      } catch (_) {
        // Never surfaces to user — silent self-healing.
      }

      // Write presence to the new couple immediately. If this is a re-pair,
      // presence.couple_id was just repaired above; stamp it active so the
      // partner can see us online right away.
      try {
        await PresenceService.setOnline(coupleId, online: true);
      } catch (_) {}
    } catch (e) {
      // TimeoutException or network error — stop loading and let the
      // router redirect to sign-in so the user is never stuck forever.
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  bool _subscribingPresence = false;

  Future<void> _subscribePresence(String coupleId) async {
    if (_subscribingPresence) return;
    _subscribingPresence = true;
    try {
      // Pattern A: fully remove the old channel (awaited) before re-creating, so
      // a reconnect never leaves a duplicate-topic 'profile-sync:<id>' channel
      // joined-but-dead (which would freeze the partner's avatar/name/status).
      final old = _presenceChannel;
      _presenceChannel = null;
      if (old != null) {
        try {
          await SupabaseService.client.removeChannel(old);
        } catch (_) {}
      }
      _presenceChannel = SupabaseRepository.subscribeToPresence(
        coupleId: coupleId,
        onPartnerUpdate: (p) {
          state = state.copyWith(partner: p);
        },
      );
    } finally {
      _subscribingPresence = false;
    }
  }

  /// Re-subscribe presence after the realtime socket is reset (app resume) so
  /// the partner's mood / avatar / online status keep updating live.
  void reconnectPresence() {
    final couple = state.couple;
    if (couple != null) _subscribePresence(couple.id);
  }

  Future<void> signOut() async {
    // FIRST, and here rather than at the call sites. Two of the four sign-out
    // buttons never called it, so the handset kept a push token on the profile
    // it was leaving: reach-notify went on addressing that couple's Reaches to
    // this device, and the next account signed in on it received them.
    // Unbinding the device is part of ending a session, not a courtesy the
    // caller can forget — and it must happen while the session is still valid,
    // because the token is cleared with an authenticated write.
    await FcmService.forgetDevice();
    final ch = _presenceChannel;
    _presenceChannel = null;
    if (ch != null) {
      try {
        await SupabaseService.client.removeChannel(ch);
      } catch (_) {}
    }
    await SupabaseRepository.signOut();
    // Both are process-scoped and outlive the session: a map of live signed
    // URLs to this couple's storage objects, and uploads accepted for it.
    // Neither belongs to whoever signs in on this handset next.
    MediaUrls.clear();
    MapToken.clear();
    ChatSendQueue.instance.clear();
    // Ciphertext too, unlike a cover raise. Raising the cover keeps the disk
    // layer because it is unreadable without the key and re-fetching it every
    // time someone glances at their phone is a great deal of traffic for
    // nothing; signing out is different, because the next account on this
    // handset has no business inheriting the previous couple's objects.
    unawaited(EncryptedMediaCache.clearAll());
    state = const SessionState(loading: false);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    final ch = _presenceChannel;
    _presenceChannel = null;
    if (ch != null) SupabaseService.client.removeChannel(ch);
    super.dispose();
  }
}

// (RealtimeChannel used above comes from the supabase_flutter import.)
final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier()..init();
});
