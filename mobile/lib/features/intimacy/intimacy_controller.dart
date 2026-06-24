import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/features/intimacy/intimacy_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class IntimacyState {
  const IntimacyState({
    this.loading = true,
    this.prefs = const IntimacyPrefs(),
    this.mine,
    this.partner,
  });

  final bool loading;
  final IntimacyPrefs prefs;
  final IntimacySignal? mine; // my active signal
  final IntimacySignal? partner; // partner's — visible only when I have one

  /// Both partners signalled within the window → the warm reveal.
  bool get mutual => mine != null && partner != null;

  /// I've signalled, but they haven't (or aren't visible) — wait gently.
  bool get waiting => mine != null && partner == null;
}

/// Owns the prefs + the mutual-consent signal state. The RLS on the table is
/// what actually keeps a partner's signal hidden until you've signalled too;
/// this controller just reflects what the server allows you to see.
class IntimacyController extends StateNotifier<IntimacyState> {
  IntimacyController(this.ref) : super(const IntimacyState()) {
    _init();
  }

  final Ref ref;
  RealtimeChannel? _channel;
  String? _coupleId;

  Future<void> _init() async {
    _coupleId = ref.read(sessionProvider).couple?.id;
    final prefs = await IntimacyRepository.getPrefs();
    state = IntimacyState(loading: false, prefs: prefs);
    final id = _coupleId;
    if (id != null) {
      _channel = IntimacyRepository.subscribe(id, refresh);
      await refresh();
    }
  }

  Future<void> refresh() async {
    final id = _coupleId;
    if (id == null) return;
    final uid = SupabaseService.currentUserId;
    try {
      final list = await IntimacyRepository.activeSignals(id);
      IntimacySignal? mine;
      IntimacySignal? partner;
      for (final s in list) {
        if (s.userId == uid) {
          mine = s;
        } else {
          partner = s;
        }
      }
      state = IntimacyState(
        loading: false,
        prefs: state.prefs,
        mine: mine,
        partner: partner,
      );
    } catch (_) {}
  }

  Future<void> setPrefs({
    required bool receiving,
    required bool signaling,
  }) async {
    await IntimacyRepository.setPrefs(
        receiving: receiving, signaling: signaling);
    if (!signaling) await IntimacyRepository.clearMine();
    state = IntimacyState(
      loading: false,
      prefs: IntimacyPrefs(
          receivingEnabled: receiving, signalingEnabled: signaling),
      mine: signaling ? state.mine : null,
      partner: state.partner,
    );
    await refresh();
  }

  Future<void> signal(String stateKey) async {
    final id = _coupleId;
    if (id == null) return;
    await IntimacyRepository.sendSignal(coupleId: id, state: stateKey);
    await refresh();
  }

  /// Frictionless "not tonight" — clears your signal, no trace, no guilt.
  Future<void> notTonight() async {
    await IntimacyRepository.clearMine();
    await refresh();
  }

  /// Mute the whole layer (both directions) instantly.
  Future<void> muteAll() => setPrefs(receiving: false, signaling: false);

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }
}

final intimacyControllerProvider =
    StateNotifierProvider.autoDispose<IntimacyController, IntimacyState>(
  (ref) => IntimacyController(ref),
);
