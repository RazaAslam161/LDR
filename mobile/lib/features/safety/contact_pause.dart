import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/server_clock.dart';

/// A pause on being interrupted, not a block.
///
/// 20260601007700 built `notification_mutes` and the two RPCs that write it,
/// and nothing in Dart has ever called them. This is that call site, widened to
/// the 'contact' kind so one row covers messages, calls, Reaches and nudges
/// instead of one button each.
///
/// Three properties, all deliberate:
///   · SILENT. The partner is not told and has nothing to read. A stop that
///     announces itself is one nobody in a controlling relationship can afford
///     to use, which makes it not a stop at all.
///   · REVERSIBLE. Nothing is deleted, the couple is not dissolved, and the
///     messages still arrive — they simply wait until the app is opened.
///   · ONE-WAY. It governs what reaches THIS phone. It does not stop the user
///     from sending, because "I want quiet" and "I want to leave" are different
///     things and only one of them is being asked for.
class ContactPause {
  ContactPause._();

  /// The umbrella kind. `push_muted` reads it in addition to whichever specific
  /// kind a notifier asks about, so a channel added later is covered without
  /// another row.
  static const kind = 'contact';

  static bool _set = false;
  static DateTime? _expiresAt;

  /// Repainted by Settings. Also read by the call controller on every inbound
  /// signal, which is why the answer is a field rather than a query.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Against the SERVER's clock. The expiry was computed by Postgres from
  /// `now()`, and a handset whose own clock is an hour out would otherwise lift
  /// the pause an hour early or hold it an hour late.
  static bool get isActive =>
      _set && (_expiresAt == null || _expiresAt!.isAfter(ServerClock.now()));

  /// Null while paused indefinitely, and meaningless when [isActive] is false.
  static DateTime? get expiresAt => _expiresAt;

  /// Adopt a `notification_mutes` row, or its absence.
  ///
  /// Split out of [load] so the expiry arithmetic is reachable without a
  /// database — the interesting cases are all about time, not about fetching.
  @visibleForTesting
  static void applyRow(Map<String, dynamic>? row) {
    _set = row != null;
    final raw = row?['expires_at'] as String?;
    _expiresAt = raw == null ? null : DateTime.parse(raw).toUtc();
    active.value = isActive;
  }

  static Future<void> load() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) {
      reset();
      return;
    }
    try {
      final row = await SupabaseService.client
          .from('notification_mutes')
          .select('expires_at')
          .eq('user_id', uid)
          .eq('kind', kind)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      applyRow(row);
    } catch (e) {
      // Fails OPEN, which is the opposite of TermsGate and is the right way
      // round here: this flag only ever DROPS an incoming ring. Guessing
      // "paused" from a read that failed would silence a call nobody asked to
      // silence, and the server-side mute is the real enforcement anyway.
      debugPrint('[pause] state unreadable, treating as off: ${e.runtimeType}');
      reset();
    }
  }

  /// [minutes] null pauses until it is lifted by hand.
  static Future<void> pause(int? minutes) async {
    await SupabaseService.client.rpc<void>('mute_partner', params: {
      'p_kind': kind,
      'p_minutes': minutes,
    },);
    await load();
  }

  static Future<void> resume() async {
    await SupabaseService.client.rpc<void>('unmute_partner', params: {
      'p_kind': kind,
    },);
    applyRow(null);
  }

  /// Sign-out and account switch. Device-scoped state that outlives an account
  /// is how one person's settings end up applying to the next one.
  static void reset() => applyRow(null);
}
