import 'package:miles/core/crypto_core.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// All Supabase queries go through here so the screens stay thin.
///
/// These calls rely on RLS policies from supabase/schema.sql to enforce that
/// a user can only read/write rows tied to their own couple.
class SupabaseRepository {
  SupabaseRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  // ─── Auth ────────────────────────────────────────────────────

  static Future<void> signUp({
    required String email,
    required String password,
  }) async {
    await _c.auth.signUp(email: email, password: password);
  }

  static Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await _c.auth.signInWithPassword(email: email, password: password);
  }

  /// Emails a password-reset link.
  ///
  /// Its absence meant a forgotten password locked someone out of their account
  /// permanently, with no self-serve way back — the account was simply gone.
  ///
  /// Deliberately does NOT report whether the address is registered: the caller
  /// shows the same message either way, so this cannot be used to discover who
  /// has an account.
  static Future<void> sendPasswordReset(String email) async {
    await _c.auth.resetPasswordForEmail(email.trim());
  }

  static Future<void> signInWithGoogle() async {
    // Native Google sign-in requires the google_sign_in package + config.
    // For v1 we ship email-only; Google lands in v1.1.
    throw UnimplementedError('Google sign-in arrives in v1.1');
  }

  static Future<void> signOut() async {
    await _c.auth.signOut();
  }

  // ─── Profile ─────────────────────────────────────────────────

  static Future<Profile?> fetchMyProfile() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;

    final res = await _c.from('profiles').select().eq('id', uid).maybeSingle();

    if (res == null) return null;
    return Profile.fromJson(res);
  }

  static Future<Profile?> fetchPartner(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    final res = await _c
        .from('profiles')
        .select()
        .eq('couple_id', coupleId)
        .neq('id', uid!)
        .maybeSingle();

    if (res == null) return null;
    return Profile.fromJson(res);
  }

  static Future<void> upsertProfile({
    required String displayName,
    required String timezone,
    String? birthDate,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) throw StateError('Not signed in');

    await _c.from('profiles').upsert({
      'id': uid,
      'display_name': displayName,
      'timezone': timezone,
      'presence_status': 'free',
      if (birthDate != null) 'birth_date': birthDate,
    });
  }

  static Future<void> updatePresence(PresenceStatus status) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c
        .from('profiles')
        .update({'presence_status': status.name}).eq('id', uid);
  }

  /// Toggles the couple-wide modest mode flag (hides intimacy module).
  /// Should be wrapped in a dual-consent prompt in the UI, but the schema
  /// permits either partner to flip it — modesty defaults to safe.
  static Future<void> setModestMode({
    required String coupleId,
    required bool enabled,
  }) async {
    await _c
        .from('couples')
        .update({'modest_mode': enabled}).eq('id', coupleId);
  }

  // ─── Partner key exchange (E2EE) ────────────────────────────

  /// True once this device has published a key that REPLACED a different one
  /// — i.e. a reinstall or a new phone. Everything encrypted under the old
  /// shared key is unreadable from here, permanently.
  static bool keyWasReplaced = false;

  /// Publishes the current user's X25519 public key.
  ///
  /// The private half lives in the platform keystore and is excluded from
  /// backup, so a reinstall generates a NEW pair. That is inherent to E2EE
  /// without key escrow — but it used to happen silently, and the partner's
  /// history simply rendered as an empty screen with no explanation. Detect
  /// the replacement so the UI can say what happened.
  static Future<void> publishMyPublicKey() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) throw StateError('Not signed in');
    final pub = await CryptoCore.getMyPublicKeyB64();

    final existing = await _c
        .from('partner_keys')
        .select('public_key')
        .eq('user_id', uid)
        .maybeSingle();
    final prev = existing?['public_key'] as String?;
    if (prev != null && prev != pub && prev != CryptoCore.legacyPublicKey) {
      keyWasReplaced = true;
    }

    await _c.from('partner_keys').upsert({
      'user_id': uid,
      'public_key': pub,
    });
  }

  /// The partner's published X25519 public key, or the legacy placeholder if
  /// they have not published a real one yet.
  ///
  /// Never returns null. Callers must compare against [CryptoCore.
  /// legacyPublicKey] and REFUSE to proceed — returning the placeholder used to
  /// drop Closer into plaintext mode silently, writing intimate notes and
  /// photos to Postgres as cleartext while the UI promised encryption.
  static Future<String?> fetchPartnerPublicKey(String partnerId) async {
    final row = await _c
        .from('partner_keys')
        .select('public_key')
        .eq('user_id', partnerId)
        .maybeSingle();
    return (row?['public_key'] as String?) ?? CryptoCore.legacyPublicKey;
  }

  // ─── Couple ──────────────────────────────────────────────────

  static Future<Couple> createCouple({required String timezone}) async {
    // `create_couple` is a SECURITY DEFINER RPC: it allocates a unique invite
    // code, inserts the couple, AND links the creator's profile atomically.
    // The client never reads the couples table under RLS right after insert
    // (which used to fail), and code generation/uniqueness lives server-side.
    final res = await _c.rpc<dynamic>(
      'create_couple',
      params: {'p_timezone': timezone},
    );
    return Couple.fromJson(_singleRow(res));
  }

  /// Permanently deletes the signed-in account and everything keyed to it.
  ///
  /// Server-side and irreversible: the RPC deletes the auth user, which
  /// cascades through profiles to every couple-scoped row, and clears the
  /// couple's storage objects once nobody is left in it.
  static Future<void> deleteMyAccount() =>
      _c.rpc<dynamic>('delete_my_account');

  static Future<void> joinCouple(String code) async {
    // `join_couple_by_code` validates the code, enforces the 2-member cap, and
    // links the profile server-side. We translate its raised errors to the
    // friendly messages the UI already expects.
    try {
      await _c.rpc<dynamic>(
        'join_couple_by_code',
        params: {'p_code': code},
      );
    } on PostgrestException catch (e) {
      if (e.message.contains('invalid_code')) {
        throw StateError('We could not find that code.');
      }
      if (e.message.contains('couple_full')) {
        throw StateError('This couple already has two members.');
      }
      rethrow;
    }
  }

  // ─── Pairing invites (expiring, single-use) ──────────────────────

  /// The caller's live invite, if they already made one.
  ///
  /// Sharing a code REQUIRES leaving the app, and leaving the app tears the
  /// whole widget tree down behind the disguise cover. Holding the code only in
  /// widget state meant it was gone the moment it was used for its one purpose:
  /// the row was still in the database, the partner still had the code, and the
  /// person who created it could never see it again. The server is the truth;
  /// the screen is a view of it.
  ///
  /// RLS already scopes this to the caller's own couple
  /// (pairing_invites_select_member), so no filter on created_by is needed.
  static Future<({String code, DateTime expiresAt})?> activePairingInvite() async {
    final rows = await _c
        .from('pairing_invites')
        .select('code, expires_at')
        .isFilter('consumed_at', null)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    final m = rows.first;
    return (
      code: JsonUtils.parseString(m['code']),
      expiresAt: JsonUtils.parseDate(m['expires_at']).toLocal(),
    );
  }

  /// Creates the caller's couple if needed and returns a fresh 6-char invite
  /// code with its expiry. Replaces the permanent invite code.
  static Future<({String code, DateTime expiresAt})> createPairingInvite({
    int ttlMinutes = 1440,
  }) async {
    final res = await _c.rpc<dynamic>(
      'create_pairing_invite',
      params: {'p_ttl_minutes': ttlMinutes},
    );
    final m = _singleRow(res);
    return (
      code: JsonUtils.parseString(m['code']),
      expiresAt: JsonUtils.parseDate(m['expires_at']).toLocal(),
    );
  }

  /// Redeems an invite code and joins the inviter's couple (validated server
  /// side: expiry, single-use, capacity).
  static Future<void> redeemPairingInvite(String code) async {
    try {
      await _c.rpc<dynamic>(
        'redeem_pairing_invite',
        params: {'p_code': code},
      );
    } on PostgrestException catch (e) {
      final m = e.message;
      if (m.contains('invalid_code')) {
        throw StateError('We couldn\'t find that code.');
      }
      if (m.contains('expired')) {
        throw StateError('That code has expired — ask for a new one.');
      }
      if (m.contains('already_used')) {
        throw StateError('That code has already been used.');
      }
      if (m.contains('couple_full')) {
        throw StateError('That couple already has two people.');
      }
      if (m.contains('already_paired')) {
        throw StateError('You\'re already linked with someone.');
      }
      rethrow;
    }
  }

  // ─── Profile + couple management ─────────────────────────────────

  /// Update editable profile fields (only non-null ones are written).
  static Future<void> updateMyProfile({
    String? displayName,
    String? timezone,
    String? statusMessage,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final patch = <String, dynamic>{};
    if (displayName != null) patch['display_name'] = displayName;
    if (timezone != null) patch['timezone'] = timezone;
    if (statusMessage != null) patch['status_message'] = statusMessage;
    if (patch.isEmpty) return;
    await _c.from('profiles').update(patch).eq('id', uid);
  }

  /// Unlink from the partner (dissolves the couple; data preserved server-side).
  static Future<void> leaveCouple() async {
    await _c.rpc<dynamic>('leave_couple');

    // The SQL function clears presence server-side, but we also do it
    // client-side for instant effect. Best-effort — never surface an error.
    try {
      final uid = SupabaseService.currentUserId;
      if (uid != null) {
        await _c.from('presence').update({
          'couple_id': null,
          'is_online': false,
          'app_last_active_at': null,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('user_id', uid);
      }
    } catch (_) {
      // Swallow errors — presence cleanup is best-effort.
    }

    // Refresh the auth session so anything keyed off the JWT re-resolves, and
    // so the resulting token-refresh event re-runs loadProfile() into a clean
    // no-couple state. Best-effort — offline just means the next load heals it.
    try {
      await SupabaseService.client.auth.refreshSession();
    } catch (_) {}
  }

  /// Sets the user's avatar URL (Issue 7 — profile photo).
  static Future<void> setAvatarUrl(String url) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('profiles').update({'avatar_url': url}).eq('id', uid);
  }

  /// Each user sets their OWN gender ('male' | 'female'); gates the cycle
  /// feature. Marks gender_set so the role-setup screen isn't shown again.
  static Future<void> setGender(String gender) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c
        .from('profiles')
        .update({'gender': gender, 'gender_set': true}).eq('id', uid);
  }

  /// Per-user chat theme (Issue 5). Each partner has their own.
  static Future<void> setChatTheme(String themeId, {String? bgUrl}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final patch = <String, dynamic>{'chat_theme_id': themeId};
    if (themeId == 'custom') patch['chat_bg_image_url'] = bgUrl;
    await _c.from('profiles').update(patch).eq('id', uid);
  }

  static Future<({String themeId, String? bgUrl})> getChatTheme() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return (themeId: 'velvet', bgUrl: null);
    final res = await _c
        .from('profiles')
        .select('chat_theme_id, chat_bg_image_url')
        .eq('id', uid)
        .maybeSingle();
    return (
      themeId: JsonUtils.parseString(res?['chat_theme_id'], fallback: 'velvet'),
      bgUrl: JsonUtils.parseStringOrNull(res?['chat_bg_image_url']),
    );
  }

  /// Persists (or clears) this device's FCM push token on the user's profile.
  /// Pass null on sign-out so stale devices stop receiving Reach pushes.
  static Future<void> setFcmToken(String? token) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('profiles').update({
      'fcm_token': token,
      'fcm_token_updated_at':
          token == null ? null : DateTime.now().toUtc().toIso8601String(),
    }).eq('id', uid);
  }

  /// A Postgres function returning a single composite row comes back as either
  /// a JSON object or a one-element list depending on the PostgREST version.
  /// Normalise both into a plain map.
  static Map<String, dynamic> _singleRow(dynamic res) {
    if (res is List) {
      return Map<String, dynamic>.from(res.first as Map);
    }
    return Map<String, dynamic>.from(res as Map);
  }

  // ─── Visits (countdown) ─────────────────────────────────────

  static Future<Visit?> fetchNextVisit(String coupleId) async {
    final res = await _c
        .from('visits')
        .select()
        .eq('couple_id', coupleId)
        .eq('is_upcoming', true)
        .order('start_date', ascending: true)
        .limit(1)
        .maybeSingle();

    if (res == null) return null;
    return Visit.fromJson(res);
  }

  static Future<void> setNextVisit({
    required String coupleId,
    required DateTime startDate,
    String? location,
  }) async {
    // Mark any prior upcoming visit as past, then insert the new one.
    await _c
        .from('visits')
        .update({'is_upcoming': false})
        .eq('couple_id', coupleId)
        .eq('is_upcoming', true);

    await _c.from('visits').insert({
      'couple_id': coupleId,
      'start_date': startDate.toUtc().toIso8601String(),
      'location': location,
      'is_upcoming': true,
    });
  }

  /// Realtime subscription: emits when either partner's presence changes.
  static RealtimeChannel subscribeToPresence({
    required String coupleId,
    required void Function(Profile) onPartnerUpdate,
  }) {
    // Distinct channel name from the presence-table subscription so the two
    // don't collide on one client (both were 'presence:$coupleId').
    return _c
        .channel('profile-sync:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) {
            final newProfile = payload.newRecord;
            if (newProfile['id'] != SupabaseService.currentUserId) {
              onPartnerUpdate(Profile.fromJson(newProfile));
            }
          },
        )
        .subscribe();
  }
}
