import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:miles/core/data/key_escrow.dart';

/// Whether a device whose escrow did not restore has actually LOST a key.
///
/// Top-level, like [argon2idDerive], so the decision can be tested without the
/// keystore and the network the three inputs come from. It used to read
/// `!hasSeed || isKeyless` inline, which walled every brand-new account: the
/// seed is minted lazily, so a first sign-in has none and looked identical to a
/// wipe.
///
/// [hadPriorIdentity] is the only input that can tell those apart — a public
/// key this account published that this device can no longer produce.
bool strandedAfterRestore({
  required bool alreadyKeyless,
  required bool hasSeed,
  required bool hadPriorIdentity,
}) =>
    alreadyKeyless || (!hasSeed && hadPriorIdentity);

/// What checking someone's password actually established.
///
/// Two failures, because "no" and "we could not ask" are different sentences
/// and the gates that use this were saying the first one for both.
enum ReauthOutcome {
  /// The password is theirs.
  ok,

  /// The server rejected the credential. This is the only outcome that may be
  /// shown as "that isn't your password".
  wrongPassword,

  /// Nobody answered, or answered something that is not about the password —
  /// a rate limit, a 5xx, a dead socket, no session to check against. The
  /// caller should offer the gate again, not accuse the user.
  unavailable,
}

/// What an auth failure during a password check actually means.
///
/// Top-level and pure for the same reason as [strandedAfterRestore]: the input
/// arrives over a network a unit test cannot have, and the decision is the part
/// worth pinning. 400 is the only status GoTrue answers with when it rejected
/// the credential — a 429 from the rate limiter is 429, a server error is 5xx,
/// and a request that never got a reply carries no status at all. Reading any
/// of those as a wrong password is how a gate accuses someone who typed it
/// correctly.
ReauthOutcome reauthOutcomeFor(AuthException e) => e.statusCode == '400'
    ? ReauthOutcome.wrongPassword
    : ReauthOutcome.unavailable;

/// What a password change did to this device's key backup.
///
/// Three outcomes because the screen has three honest things to say, and used
/// to say the first one for all of them.
enum PasswordChangeOutcome {
  /// The escrow is re-sealed under the new password — or there was no key on
  /// this device to seal, which is the ordinary state of an account that has
  /// not opened a screen that mints one. Neither needs explaining.
  settled,

  /// A key is on this device but the re-seal did not take. The escrow is still
  /// sealed under the password just replaced, so nobody can open it: this
  /// phone is now the only copy of the couple's key.
  escrowStale,

  /// This device cannot read the couple's history. The partner holds the key
  /// and the router sends them to the ceremony.
  keyless,
}

/// What a password change did to the key backup, from the three facts that
/// decide it.
///
/// Top-level and pure for the same reason as [strandedAfterRestore]: the inputs
/// come from the keystore and the network, and the decision is the part worth
/// pinning. [publishedIdentity] is only consulted when there is no seed here,
/// where it separates a real reinstall from an account that simply has not
/// opened a screen that mints one yet.
PasswordChangeOutcome passwordChangeOutcome({
  required bool hasSeed,
  required bool publishedIdentity,
  required bool escrowWritten,
}) {
  if (!hasSeed) {
    return publishedIdentity
        ? PasswordChangeOutcome.keyless
        : PasswordChangeOutcome.settled;
  }
  return escrowWritten
      ? PasswordChangeOutcome.settled
      : PasswordChangeOutcome.escrowStale;
}

/// All Supabase queries go through here so the screens stay thin.
///
/// These calls rely on RLS policies from supabase/schema.sql to enforce that
/// a user can only read/write rows tied to their own couple.
class SupabaseRepository {
  SupabaseRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  // ─── Auth ────────────────────────────────────────────────────

  /// Where Supabase sends the user back to after they tap a link in an email.
  ///
  /// An https:// page rather than the `tethered://auth-callback` scheme this
  /// used to be. A custom scheme is invisible to everything that is not the
  /// phone holding the app: Gmail's in-app browser blocks it, a desktop has no
  /// handler for it at all, and an uninstalled app leaves a blank tab. Every
  /// one of those is a new user's FIRST interaction with Miles, and it showed
  /// them nothing — no page, no branding, no explanation.
  ///
  /// The page forwards whatever arrives to `tethered://auth-callback`
  /// unchanged, so the app-side flow below is untouched: gotrue still redeems
  /// the token, and `_handleLink` in main.dart still refuses to trust the
  /// intent itself.
  /// Where it cannot hand off — a desktop, which under PKCE can never hold the
  /// code verifier — it says so instead of failing silently.
  ///
  /// MUST be listed under Authentication -> URL Configuration -> Redirect URLs
  /// in the Supabase dashboard. If it is not, Supabase ignores it and falls
  /// back to the project's Site URL, which is how every confirmation mail once
  /// opened "localhost refused to connect" on a phone.
  ///
  /// The old scheme stays registered in AndroidManifest.xml and must not be
  /// removed: mails already sent carry it, and shipped builds still redeem it.
  static const authCallbackUrl =
      'https://miles-legal.vercel.app/auth-callback.html';

  static Future<void> signUp({
    required String email,
    required String password,
  }) async {
    final res = await _c.auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: authCallbackUrl,
    );
    // Read off the RESPONSE, never off currentUser.
    //
    // gotrue only swaps the stored session when the reply carries one, and with
    // email confirmation on it never does. `currentUser` was therefore whoever
    // was signed in BEFORE this call — so a second account created on a handset
    // that still held a session bound key storage to the first account and
    // sealed its seed under a password that account will never sign in with.
    // The owner discovers it on their next reinstall, as a MAC failure nothing
    // reports and a history nobody can open.
    //
    // No session means no account to act for yet. The escrow this used to
    // attempt here could never have written a row anyway: the wrap needs a
    // seed, and the seed is not minted until something asks for the keypair.
    if (res.session == null) return;
    final uid = res.user?.id;
    if (uid == null) return;
    await CryptoCore.bindAccount(uid);
    await _backupEscrow(password);
  }

  static Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await _c.auth.signInWithPassword(email: email, password: password);

    // Bind key storage to this account before any of it is read or written, so
    // a restore lands under this user's key and not the previous signed-in
    // account's.
    final uid = _c.auth.currentUser?.id;
    if (uid != null) await CryptoCore.bindAccount(uid);

    // Recover the encryption key before anything reads encrypted rows.
    //
    // Android wipes FlutterSecureStorage on uninstall, so a reinstall used to
    // mint a new X25519 keypair and silently orphan every memory and vault
    // item the couple had written. Restoring first means a fresh
    // install adopts the ORIGINAL key rather than generating a replacement that
    // can never open anything.
    //
    // Order matters: restore, then back up. Backing up first would seal the
    // brand-new throwaway key over the good one and make the loss permanent.
    if (!await KeyEscrow.restore(password)) {
      // Nothing came back, so decide whether this device has actually LOST a
      // key — recorded rather than navigated, because a `context.go` from the
      // sign-in page loses the race with the redirect the auth event has
      // already started, and a cold start never comes back through here.
      //
      // "No seed on this device" alone is not evidence of loss. The seed is
      // minted lazily, the first time anything asks for the keypair, so every
      // brand-new account has none at its first sign-in — and reading that as a
      // wipe walled every new user behind a ceremony asking their partner to
      // send back a key neither of them had ever had. It re-armed on each
      // sign-in, because `deferRecovery` leaves `isKeyless` true.
      //
      // A published public key this device can no longer produce is evidence.
      // Nothing else here distinguishes the two cases.
      final alreadyKeyless = await CryptoCore.isKeyless();
      final hasSeed = await CryptoCore.hasSeed();
      // Asked only when it can still change the answer, so an ordinary sign-in
      // on a phone that holds its key does not pay for a round trip. Null is
      // "could not tell" — neither evidence of loss nor evidence of a first
      // run, and both decisions below refuse to act on it.
      final published =
          alreadyKeyless || hasSeed ? null : await _publishedIdentity();
      final stranded = strandedAfterRestore(
        alreadyKeyless: alreadyKeyless,
        hasSeed: hasSeed,
        // Unknown counts as LOST, and the asymmetry is the reason. Walling
        // someone who was fine costs a screen they can tap past. Clearing
        // someone who was stranded costs the couple's history: they are never
        // routed to the ceremony, mint a stand-in on the first Closer screen,
        // and the sign-in after that escrows it over the row that still held
        // the real seed. The old line marked unconditionally and was never
        // wrong in this direction; `?? false` made it wrong on any sign-in
        // where this one lookup happened to fail.
        hadPriorIdentity: published ?? true,
      );
      // Two positive answers, not one. The server has no published key for this
      // account AND no escrow row: nothing existed here before, so minting the
      // seed now costs nothing and finally gives the backup below something to
      // seal — which it never had at a first sign-in, and why production
      // carried two escrow rows against six accounts.
      //
      // Either signal being unknown mints nothing. `published` is null when the
      // lookup could not be made; `isMissing` answers false when it cannot
      // reach the server. A phone that minted on a guess would seal a stand-in
      // over the row still holding the couple's real key, which is the one
      // outcome nothing here may risk.
      if (!stranded && published == false && await KeyEscrow.isMissing()) {
        await CryptoCore.ensureSeed();
      }
      await _backupEscrow(password);
      if (stranded) await CryptoCore.markKeyless();
    }
  }

  /// Seals the key under [password], and says so when it does not.
  ///
  /// Neither caller can show a failure: signUp has not drawn a screen yet, and
  /// a `context.go` from the sign-in page loses the race with the redirect the
  /// auth event has already started — which is why the bool was dropped on the
  /// floor at both. Dropping it left the one write that protects every
  /// encrypted row this couple owns with no field-visible trace at all, so
  /// "how many accounts have no escrow row" was a question nobody could answer
  /// from anywhere but a cable. EscrowPrompt still heals the user's side on the
  /// next launch; this is the half that reaches the maintainer.
  ///
  /// The account is not named here and does not need to be: `client_errors`
  /// defaults `user_id` to `auth.uid()` (20260601007800), so the row that lands
  /// already carries whose escrow it was.
  static Future<void> _backupEscrow(String password) async {
    if (await KeyEscrow.backup(password)) return;
    ErrorReporter.report(
      StateError('escrow backup did not take'),
      StackTrace.current,
      kind: 'escrow-backup',
    );
  }

  /// Whether this account has ever published a real X25519 public key.
  ///
  /// Answers "did this account once have an identity this device can no longer
  /// produce?" — the question [signIn] needs and the local keystore cannot
  /// answer, since a reinstall and a first run look identical from there.
  ///
  /// Three answers. True is evidence of loss. False means the read succeeded
  /// and showed no key. **Null means the read itself failed** — no evidence
  /// either way, and callers must not read it as "brand new": that is how a
  /// stranded phone mints a stand-in and escrows it over the real row. Both
  /// callers default an unknown to LOST.
  ///
  /// False used to be ambiguous, and is not any more. `partner_keys_select_member`
  /// scopes reads to the caller's couple, so an unpaired account saw no row
  /// whether or not one existed — RLS filters rather than errors, so
  /// `.maybeSingle()` answered null without throwing and false covered both
  /// "never published" and "unpaired, so hidden".
  ///
  /// The comment here used to argue that was survivable, because an unpaired
  /// account has no partner and so nobody to answer the ceremony that false
  /// would skip. Severance breaks that argument: a dissolved couple has a way
  /// back, so an unpaired account still has someone who could answer, and a
  /// reinstall during that window is exactly the case the silence stranded.
  ///
  /// `partner_keys_select_own` (20260826150000) ORs a self-row read beside the
  /// couple-scoped one, so this read is now authoritative in both directions.
  /// Null still means the read FAILED and still must not be taken as "brand
  /// new".
  static Future<bool?> _publishedIdentity() async {
    try {
      final uid = _c.auth.currentUser?.id;
      if (uid == null) return null;
      final row = await _c
          .from('partner_keys')
          .select('public_key')
          .eq('user_id', uid)
          .maybeSingle();
      final pub = row?['public_key'] as String?;
      return pub != null && pub != CryptoCore.legacyPublicKey;
    } catch (e) {
      debugPrint('[auth] published-identity lookup failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Confirms [password] really belongs to the signed-in account.
  ///
  /// The escrow prompt is the one place a password arrives unverified, and the
  /// wrap it produces can never be checked afterwards by anybody: a typo seals
  /// a row that opens for nobody and looks exactly like a good one. Signing in
  /// again is the only check a client has.
  ///
  /// True only for [ReauthOutcome.ok]. Screens that can say more than "no"
  /// should call [reauthenticateOutcome] instead — this narrowing is what
  /// makes an emergency exit look inert during a rate limit.
  static Future<bool> reauthenticate(String password) async =>
      await reauthenticateOutcome(password) == ReauthOutcome.ok;

  /// Why the check did not pass, so a caller can stop blaming the user.
  ///
  /// Every failure used to collapse to a bare false, unlogged, and every
  /// caller renders that as "that isn't your password" — which is a lie for a
  /// 429 from the rate limiter, for a 5xx, and for a socket that died
  /// mid-request. GoTrue answers 400 for a credential it rejected and
  /// something else for everything that is not the user's fault, so those are
  /// the two answers this returns.
  static Future<ReauthOutcome> reauthenticateOutcome(String password) async {
    final email = _c.auth.currentUser?.email;
    // No session to check against is not a wrong password either.
    if (email == null) return ReauthOutcome.unavailable;
    try {
      await _c.auth.signInWithPassword(email: email, password: password);
      return ReauthOutcome.ok;
    } on AuthException catch (e) {
      // The status and the machine code, never the message and never the
      // address — this runs on the emergency gate and logcat is readable over
      // a cable by whoever holds the phone.
      debugPrint('[auth] reauthenticate refused: ${e.statusCode} ${e.code}');
      return reauthOutcomeFor(e);
    }
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
    await _c.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: authCallbackUrl,
    );
  }

  /// Sets a new password for the session opened by a recovery link.
  ///
  /// Returns what became of the key backup, because "the password changed" and
  /// "your history is still recoverable" are different facts and the screen was
  /// printing the first over a silent failure of the second.
  static Future<PasswordChangeOutcome> updatePassword(String newPassword) async {
    // Bound first, like sign-in: key material is stored per account, and a
    // recovery link can land here before loadProfile has bound anything — in
    // which case both the question below and the mark further down would go to
    // the unscoped names, where nothing reads them again.
    final uid = _c.auth.currentUser?.id;
    if (uid != null) await CryptoCore.bindAccount(uid);
    // Asked before anything changes, because the answer decides whether the
    // escrow row may be touched at all — and reading the seed is what mints one
    // when it is absent, so a moment later this can no longer be answered.
    final hasSeed = await CryptoCore.hasSeed();
    await _c.auth.updateUser(UserAttributes(password: newPassword));
    // "No seed here" is not by itself a reinstall — the seed is minted lazily,
    // so an account that resets before ever opening a screen that mints one
    // looks identical. Marking that keyless walled people out of a couple that
    // had written nothing, permanently, on a password reset. Same evidence as
    // [signIn]: a published key this device can no longer produce.
    //
    // The escrow, when there IS a seed, is sealed under the OLD password — the
    // one just forgotten. Left alone, the next reinstall fails to open it,
    // mints a throwaway key, and the following sign-in escrows that over the
    // good row. This is the one moment both halves exist, and the boolean
    // backup returns is the whole reason it returns one: a refusal leaves the
    // escrow sealed under a password nobody knows, and the screen used to print
    // "Password updated" over it either way.
    final outcome = passwordChangeOutcome(
      hasSeed: hasSeed,
      // `?? true` for the same reason as [signIn]: a lookup that failed is not
      // permission to treat a reinstall as a first run.
      publishedIdentity: !hasSeed && (await _publishedIdentity() ?? true),
      escrowWritten: hasSeed && await KeyEscrow.backup(newPassword),
    );
    if (outcome == PasswordChangeOutcome.keyless) {
      await CryptoCore.markKeyless();
    }
    return outcome;
  }

  /// Asks the server to move this account to [newEmail].
  ///
  /// Nothing has changed when this returns: Supabase's secure-email-change
  /// default mails a confirmation link to BOTH mailboxes — the current address
  /// and the new one — and the account only moves once both are opened. That
  /// double confirmation is the point, not friction: whoever is holding an
  /// unlocked phone cannot quietly re-home the account to an address they
  /// control, because the mailbox they do not hold has to agree.
  ///
  /// E2EE is unaffected. Email is a sign-in name and nothing more in this app:
  /// the couple key comes from the device seed and the escrow is sealed under
  /// the password, neither derived from the address — so no re-wrap, no
  /// re-publish and no ceremony follows a change.
  static Future<void> changeEmail(String newEmail) async {
    await _c.auth.updateUser(
      UserAttributes(email: newEmail.trim()),
      emailRedirectTo: authCallbackUrl,
    );
  }

  static Future<void> signInWithGoogle() async {
    // Native Google sign-in requires the google_sign_in package + config.
    // For v1 we ship email-only; Google lands in v1.1.
    throw UnimplementedError('Google sign-in arrives in v1.1');
  }

  static Future<void> signOut() async {
    await _c.auth.signOut();
  }

  /// Revokes every session this account holds EXCEPT this device's.
  ///
  /// The scenario is a handset that is gone — lost, stolen, traded in, or an
  /// old install nobody can reach — still signed in and still able to open
  /// everything. [SignOutScope.others] is what keeps THIS session alive:
  /// gotrue skips the local session removal entirely for that scope (it fires
  /// no signedOut event here), so the device the user is holding stays signed
  /// in while the server invalidates the rest.
  static Future<void> signOutOtherDevices() async {
    // gotrue swallows 401/403/404 from this endpoint and returns normally —
    // an expired local JWT would revoke nothing while Settings toasts
    // success. Refreshing first either yields a token the revoke accepts or
    // throws, which the caller surfaces. In a lost-phone feature the one
    // unacceptable outcome is a silent no-op.
    await _c.auth.refreshSession();
    await _c.auth.signOut(scope: SignOutScope.others);
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
    // Refused, not deferred — and FIRST, before keyWasReplaced can be set. A
    // rewrap in flight means the partner is about to seal the OLD couple key
    // to this device's new public key; publishing it first rotates the key
    // they are sealing against, and the blob that lands opens nothing.
    // Checked before the replacement probe too: flagging keyWasReplaced
    // mid-ceremony makes Closer announce "gone forever" about the exact
    // content the ceremony is minutes from restoring.
    if (await CryptoCore.publicationHeld()) return;

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

  // joinCouple lived here and called join_couple_by_code, which 003200 dropped
  // and 003700's own comment already noted was "gone so nothing reads it
  // today". It had no callers, so it never threw — it just sat waiting to
  // PGRST202 the first time anyone wired it to a button. Pairing goes through
  // create_pairing_invite / redeem_pairing_invite below.

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

  /// Creates the caller's couple if needed and returns a fresh 8-char invite
  /// code with its expiry. Replaces the permanent invite code.
  static Future<({String code, DateTime expiresAt})> createPairingInvite({
    int ttlMinutes = 1440,
  }) async {
    final res = await _c.rpc<dynamic>(
      'create_pairing_invite',
      params: {'p_ttl_minutes': ttlMinutes},
    );
    final m = _singleRow(res);
    await _publishKeyForPairing('invite');
    return (
      code: JsonUtils.parseString(m['code']),
      expiresAt: JsonUtils.parseDate(m['expires_at']).toLocal(),
    );
  }

  /// Publish this device's public key as part of pairing, for both sides.
  ///
  /// Until now the ONLY things that published were Closer's entry point, the
  /// rewrap ceremony, and the settings toggle — and Closer skips key prep
  /// entirely while `couples.modest_mode` is on, which is the DEFAULT. A couple
  /// that never opened Closer therefore had no key published, so nothing
  /// outside Closer could ever encrypt for them. Pairing is the honest moment:
  /// it is the first instant two accounts are known to each other, and it
  /// happens exactly once per couple.
  ///
  /// Best effort on purpose. publishMyPublicKey refuses while a rewrap is held
  /// and can fail on a bad connection, and neither is a reason to fail the
  /// pairing the user is standing in front of — the key is re-published from
  /// the chat path (CoupleKey.ensure) on the next open.
  static Future<void> _publishKeyForPairing(String stage) async {
    try {
      await publishMyPublicKey();
    } catch (e) {
      debugPrint('[key] pairing($stage): publish failed, will retry on '
          'chat open: ${e.runtimeType} $e');
    }
  }

  /// Redeems an invite code and joins the inviter's couple (validated server
  /// side: expiry, single-use, capacity).
  static Future<void> redeemPairingInvite(String code) async {
    try {
      await _c.rpc<dynamic>(
        'redeem_pairing_invite',
        params: {'p_code': code},
      );
      // Only after the redeem succeeded: a failed code means no couple, and
      // publishing then would be a write on behalf of a pairing that did not
      // happen.
      await _publishKeyForPairing('redeem');
    } on PostgrestException catch (e) {
      final m = e.message;
      if (m.contains('invalid_code')) {
        throw StateError("We couldn't find that code.");
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
      // Raised when the code still points at a couple somebody has since left
      // (20260815071024). It had no branch here, so the one error whose cause
      // the user can actually act on — ask for a new code — reached them as a
      // raw PostgrestException string.
      if (m.contains('couple_dissolved')) {
        throw StateError('That code belongs to a couple that no longer '
            'exists — ask for a new one.');
      }
      if (m.contains('already_paired')) {
        throw StateError("You're already linked with someone.");
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
    // Thrown like upsertProfile above, not returned: Settings awaits this and
    // then toasts 'Updated', so a silent return told the user a write happened
    // that never did. Same guard on setAvatarUrl and setGender below.
    if (uid == null) throw StateError('Not signed in');
    final patch = <String, dynamic>{};
    if (displayName != null) patch['display_name'] = displayName;
    if (timezone != null) patch['timezone'] = timezone;
    if (statusMessage != null) patch['status_message'] = statusMessage;
    if (patch.isEmpty) return;
    await _c.from('profiles').update(patch).eq('id', uid);
  }

  /// What, if anything, is still recoverable from the couple that ended.
  ///
  /// Returns null for every negative case — never a member, severed, window
  /// expired, already purged, paired with somebody else. That uniformity is
  /// deliberate on the server side and must not be unpicked here: it is what
  /// stops this call telling an ex whether the other person chose the
  /// permanent exit or simply let the clock run out.
  static Future<Map<String, dynamic>?> coupleRestoreState() async {
    final row = await _c.rpc<dynamic>('couple_restore_state');
    return row == null ? null : Map<String, dynamic>.from(row as Map);
  }

  /// Ask to reconnect. Cannot restore anything on its own.
  static Future<void> coupleRestoreRequest() =>
      _c.rpc<void>('couple_restore_request');

  /// Withdraw your own ask, or turn down theirs. The server records which it
  /// was; either way the request is closed and the person who was turned down
  /// cannot re-open it.
  static Future<void> coupleRestoreCancel() =>
      _c.rpc<void>('couple_restore_cancel');

  /// Agree to the other person's ask, which restores the couple.
  ///
  /// The server refuses this if you are the one who asked. That check is the
  /// whole guarantee and it deliberately does not live here.
  static Future<void> coupleRestoreConfirm() =>
      _c.rpc<void>('couple_restore_confirm');

  /// End it now, for both, with nothing kept.
  ///
  /// Reachable by EITHER ex-member, including the one who did not start it —
  /// a window opened over your own history by somebody else is one you must be
  /// able to close. Silent on the server when there is nothing to end.
  static Future<void> leaveCouplePermanently() =>
      _c.rpc<void>('leave_couple_permanently');

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
    // Thrown, not returned — the caller toasts success on a normal return.
    if (uid == null) throw StateError('Not signed in');
    await _c.from('profiles').update({'avatar_url': url}).eq('id', uid);
  }

  /// Each user sets their OWN gender ('male' | 'female'); gates the cycle
  /// feature. Marks gender_set so the role-setup screen isn't shown again.
  static Future<void> setGender(String gender) async {
    final uid = SupabaseService.currentUserId;
    // Thrown, not returned — the caller toasts success on a normal return.
    if (uid == null) throw StateError('Not signed in');
    await _c
        .from('profiles')
        .update({'gender': gender, 'gender_set': true}).eq('id', uid);
  }

  /// Per-user chat theme (Issue 5). Each partner has their own.
  ///
  /// [bgPath] is a storage path in `chat-bg`, despite the column's name. It
  /// held a signed URL until that URL's 24h expiry started outliving the
  /// background it pointed at; the column keeps its name because renaming it
  /// would strand every client that has not been sideloaded again.
  static Future<void> setChatTheme(String themeId, {String? bgPath}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final patch = <String, dynamic>{'chat_theme_id': themeId};
    if (themeId == 'custom') patch['chat_bg_image_url'] = bgPath;
    await _c.from('profiles').update(patch).eq('id', uid);
  }

  static Future<({String themeId, String? bgPath})> getChatTheme() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return (themeId: 'velvet', bgPath: null);
    final res = await _c
        .from('profiles')
        .select('chat_theme_id, chat_bg_image_url')
        .eq('id', uid)
        .maybeSingle();
    return (
      themeId: JsonUtils.parseString(res?['chat_theme_id'], fallback: 'velvet'),
      bgPath: JsonUtils.parseStringOrNull(res?['chat_bg_image_url']),
    );
  }

  /// Persists (or clears) this device's FCM push token on the user's profile.
  /// Pass null on sign-out so stale devices stop receiving Reach pushes.
  ///
  /// Skips the write when the token has not changed, which is almost always.
  /// registerToken() runs on EVERY resume (main.dart:328) and this wrote
  /// unconditionally, so `fcm_token_updated_at` was a durable, second-resolution
  /// record of the last time this app came to the foreground — and fetchPartner
  /// selects every column, so the partner held it. Ringing someone refreshed it,
  /// which made it a presence oracle that outlived the 45s freshness window
  /// entirely: call at 3am, see nothing on screen, read the timestamp after.
  ///
  /// The last-written value is kept on the device rather than read back, so the
  /// common path costs no round trip at all.
  ///
  /// The skip is BOUNDED to a day. It used to be forever, which asserted the
  /// wrong thing: "I wrote this once" is not "the server still has it". The
  /// row changes underneath this cache — sign into a second device and the
  /// profile carries that device's token; the claim trigger nulls the row
  /// when another profile claims this token — and a forever-skip meant the
  /// actively used handset never re-registered: zero pushes, no recovery
  /// short of reinstalling. One write a day is still too coarse to revive
  /// the presence oracle the skip was built against.
  static Future<void> setFcmToken(String? token) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'fcm_token_written:$uid';
    final atKey = 'fcm_token_written_at:$uid';
    if (token != null && prefs.getString(key) == token) {
      final at = DateTime.tryParse(prefs.getString(atKey) ?? '');
      if (at != null &&
          DateTime.now().toUtc().difference(at) < const Duration(hours: 24)) {
        return;
      }
    }
    await _c.from('profiles').update({
      'fcm_token': token,
      'fcm_token_updated_at':
          token == null ? null : DateTime.now().toUtc().toIso8601String(),
    }).eq('id', uid);
    if (token == null) {
      await prefs.remove(key);
      await prefs.remove(atKey);
    } else {
      await prefs.setString(key, token);
      await prefs.setString(atKey, DateTime.now().toUtc().toIso8601String());
    }
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
        .channel('profile-sync:$coupleId', opts: RealtimeChannelConfig(private: true))
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
