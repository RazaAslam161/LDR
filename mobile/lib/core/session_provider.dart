import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/supabase_service.dart';
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
      if (event.session != null) {
        await loadProfile();
      }
    });

    if (current != null) {
      loadProfile();
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

      if (couple != null) {
        _subscribePresence(couple.id);
      }
    } catch (e) {
      // TimeoutException or network error — stop loading and let the
      // router redirect to sign-in so the user is never stuck forever.
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void _subscribePresence(String coupleId) {
    _presenceChannel?.unsubscribe();
    _presenceChannel = SupabaseRepository.subscribeToPresence(
      coupleId: coupleId,
      onPartnerUpdate: (p) {
        state = state.copyWith(partner: p);
      },
    );
  }

  Future<void> signOut() async {
    await _presenceChannel?.unsubscribe();
    _presenceChannel = null;
    await SupabaseRepository.signOut();
    state = const SessionState(loading: false);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _presenceChannel?.unsubscribe();
    super.dispose();
  }
}

// (RealtimeChannel used above comes from the supabase_flutter import.)
final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier()..init();
});
