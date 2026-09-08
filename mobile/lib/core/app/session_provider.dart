import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/config.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/media/map_token.dart';
import 'package:miles/core/media/plain_media_cache.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/core/services/unread_tally.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/features/chat/chat_draft_store.dart';
import 'package:miles/features/chat/chat_reactions.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:miles/features/chat/voice_note_cache.dart';
import 'package:miles/features/cycle/love_notes_pool.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/gallery/gallery_repository.dart';
import 'package:miles/features/gallery/gallery_screen.dart';
import 'package:miles/features/legal/terms_gate.dart';
import 'package:miles/features/safety/contact_pause.dart';
import 'package:miles/features/safety/severance_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';
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

  /// The last [SessionNotifier.loadProfile] THREW rather than answering.
  ///
  /// A fetch that failed and a fetch that found no row both leave [profile]
  /// null, and the router used to read the two identically — so a paired user
  /// cold-starting in airplane mode waited out the timeout and was handed the
  /// blank new-user form, whose submit upserts over their real name, timezone
  /// and date of birth the moment connectivity returns. Failure has to be its
  /// own state: the router holds it on /offline until the server answers.
  bool get profileLoadFailed => profile == null && error != null;

  /// Deliberately without `session`.
  ///
  /// It used to take one, as `session: session ?? this.session` — which meant
  /// the null gotrue delivers on a signedOut event (a revoked, expired or
  /// reused refresh token) was swallowed and the app stayed authenticated
  /// against a dead token: every call 401s, the router's guard never fires,
  /// and nothing changes until the process is killed. A session now only ever
  /// changes where the whole state is rebuilt, in view.
  SessionState copyWith({
    bool? loading,
    Profile? profile,
    Couple? couple,
    Profile? partner,
    bool? partnerOnline,
    String? error,
  }) {
    return SessionState(
      loading: loading ?? this.loading,
      session: session,
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

  /// The access token [init] already took responsibility for loading.
  ///
  /// Read by the replay guard below, and set before the subscription rather
  /// than beside the load: the buffered event lands on the next microtask and
  /// would otherwise race the assignment.
  String? _seededToken;

  /// Bumped by every couple- or session-end, so a [loadProfile] whose reads
  /// were already in flight cannot publish what it fetched afterwards.
  ///
  /// A generation rather than a cancellation because there is nothing to
  /// cancel: the fetches are plain awaited requests, and the only question that
  /// matters is whether the session that asked for them still exists when they
  /// answer.
  int _generation = 0;

  /// May a run that began at [gen] still publish DEVICE-GLOBAL state?
  ///
  /// A predicate rather than one guard, because the answer expires: every await
  /// taken after a check reopens the window the check closed. loadProfile asked
  /// once, halfway down, and three publishes still lived below it — the
  /// presence subscribe, the online write and the couple-key derive — each
  /// awaiting again on the far side of that fence. A sign-out landing in any of
  /// those windows left a realtime channel joined on the ex-couple's id, this
  /// handset written online inside it, and their derived key re-parked in
  /// CoupleKey for the rest of the process. Every publish point re-asks; none
  /// of them trusts an earlier answer.
  bool _mayPublish(int gen) => gen == _generation;

  /// Bumped per loadProfile call. `_generation` says which SESSION a run
  /// belongs to; this says which RUN it is, so an abandoned one can tell
  /// whether the `loading` flag on screen is still the one it raised.
  int _loadSeq = 0;

  void init() {
    // Seed initial state from any stored session.
    final current = SupabaseService.client.auth.currentSession;
    _seededToken = current?.accessToken;
    // Same reason as the listener below: a restored session has a profile and
    // an acceptance still to fetch, and false here is the router's cue to
    // decide things it does not yet know.
    state = SessionState(loading: current != null, session: current);

    _authSub = SupabaseService.authChanges.listen((event) async {
      // The server ended it: a revoked, expired or reused refresh token. Not a
      // state to patch — everything held for that session has to go, the same
      // way it goes when the user asks.
      if (event.event == AuthChangeEvent.signedOut) {
        await _endSession();
        return;
      }
      // gotrue's onAuthStateChange is an unbounded ReplaySubject, and
      // supabase_flutter emits `initialSession` for a stored session during
      // Supabase.initialize() — before this notifier is built. So a cold start
      // with a session delivers that buffered event here for the very session
      // seeded above, and BOTH doors then loaded it: two profile reads, two
      // couples selects, two fetchPartner reads, two terms reads and up to four
      // presence writes, on every launch. The explicit call below stays the
      // reliable door; this replay is the redundant one.
      //
      // Dropped before the state write, not just before the load: that write
      // republishes loading:true, and if the seeded load had already finished
      // nothing would ever set it false again and the router would hold.
      if (event.event == AuthChangeEvent.initialSession &&
          event.session?.accessToken == _seededToken) {
        return;
      }
      // loading stays TRUE while a session exists and the profile has not been
      // fetched yet. It used to publish false here, which let the router run a
      // full redirect pass on a signed-in user whose terms acceptance had not
      // been read yet — so someone who accepted months ago was shown the whole
      // Terms screen for the length of three network calls before loadProfile
      // finally released them. loadProfile sets it false when it is actually
      // done; a session with nothing loaded behind it is not "not loading".
      state = SessionState(
        loading: event.session != null,
        session: event.session,
        profile: state.profile,
        couple: state.couple,
        partner: state.partner,
        partnerOnline: state.partnerOnline,
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
    } catch (e, st) {
      debugPrint('[tz] sync failed: $e');
      // debugPrint is nulled in release, so "the one thing that silently goes
      // wrong when someone travels" was silent in exactly the builds people
      // travel with. Every scheduled thing — rituals, capsule unlocks, the
      // daily question — is computed against the stored zone, so a failure
      // here fires all of them at the wrong hour with nothing to say why.
      ErrorReporter.report(e, st, kind: 'timezone-sync');
    }
  }

  Future<void> loadProfile() async {
    final gen = _generation;
    // Which LOAD this is, beside which SESSION it belongs to. The generation
    // alone cannot answer "may I lower the flag": two loads can share a dead
    // generation, and the abandoned one would clear a `loading` the newer one
    // raised — dropping the router onto /welcome mid-resolve.
    final load = ++_loadSeq;
    state = state.copyWith(loading: true);
    try {
      // Also here, not just at sign-in: a session restored on launch never
      // passes through signIn, and until the account is bound its key material
      // is still readable under the pre-scoping device-wide name.
      final uid = SupabaseService.currentUserId;
      if (uid != null) await CryptoCore.bindAccount(uid);
      // Both are per-ACCOUNT and both are read here rather than only at
      // startup, because a second person signing in on the same handset never
      // passes through main() again — and inheriting the first person's terms
      // acceptance, or their contact pause, is the device-scoped leak this
      // codebase has already paid for twice (FCM tokens, cached couple ids).
      await TermsGate.load();
      unawaited(ContactPause.load());
      final profile = await SupabaseRepository.fetchMyProfile()
          .timeout(const Duration(seconds: 10));
      if (profile == null) {
        // A reachable server answered "no row": a genuinely new account.
        // copyWith drops any previous error, so this lands as a definite
        // answer and is never mistaken for a failed fetch (profileLoadFailed).
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

      // The session (or the couple) ended while these reads were in flight.
      // Nothing below may run: it republishes the ex-couple into the notifier,
      // stamps its id back into SharedPreferences through SessionScope — after
      // forgetDevice had cleared it, so pushes already queued behind their 24h
      // TTL are admitted again — re-subscribes presence to it and writes us
      // online in it. One ordinary user tapping Sign out on a bad connection
      // reaches this: nothing here re-read the session after an await, and
      // signOut() holds no handle to cancel the load.
      if (!_mayPublish(gen)) {
        debugPrint('[session] loadProfile answered after the session ended');
        // The one thing this run may still publish is the flag it raised
        // itself. Returning with loading left true strands every guard in the
        // router, which deliberately decides nothing at all while a session is
        // resolving — so an unpair that races a load would never reach /couple.
        //
        // And only if no LATER load has raised it since: lowering another
        // run's flag hands the router a half-resolved session, which renders
        // the blank /welcome form over an account that is still signing in.
        if (load == _loadSeq) state = state.copyWith(loading: false);
        return;
      }

      // Which couple this handset thought it was in, read BEFORE the
      // setCouple below can clear it. A couple that is gone from the server
      // while this value still holds an id is a couple that ended while the
      // app was closed — the only way to tell that apart from an account that
      // never paired, and the difference decides whether a device wipe is owed.
      final knownCoupleId = SessionScope.coupleId ?? await SessionScope.readCouple();

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
      //
      // The fourth device-global publish, and the last one that was reading an
      // answer from the wrong side of an await. The fence above is taken here,
      // but this call is UNAWAITED and suspends on the prefs handle before it
      // writes, so a sign-out landing in that window had the ex-couple's id
      // stamped back into SharedPreferences after forgetDevice had removed it —
      // and the row, not the in-memory copy, is what the FCM background isolate
      // reads, so that couple's queued pushes (24h TTL) were admitted again on
      // a handset nobody was signed into. `stillCurrent` re-asks the same
      // predicate in the same slice as the write, which is the only moment the
      // answer is still true when it is used.
      unawaited(SessionScope.setCouple(
        couple?.id,
        stillCurrent: () => _mayPublish(gen),
      ));

      // The couple key starts deriving the moment a partner is known, not when
      // some screen happens to need it. Every encrypted write outside Closer
      // used to depend on the user's navigation history: a note sent from the
      // cycle screen or an ETA from the map went out unsealed unless the chat
      // tab had been opened earlier in the same process. Unawaited — nothing
      // here waits on it, and the derive parks itself in CoupleKey for whoever
      // asks next. Unawaited is not unsupervised, though — see _primeCoupleKey.
      if (partner != null) unawaited(_primeCoupleKey(gen));

      // An open unlinking ceremony, if this couple has one. Paired members
      // read the row straight through RLS; unawaited because the banner and
      // the screen both re-render off the notifier when it lands.
      if (couple != null) unawaited(UnlinkState.load());

      if (couple == null) {
        // The couple ended while this app was CLOSED — the partner tapped it,
        // or the ceremony completed — and this load is the first thing that
        // knows. Nothing else calls endCouple on this path: _endSession is
        // sign-out only, so the whole local teardown below it (chat drafts,
        // EncryptedMediaCache, the PLAINTEXT DefaultCacheManager store, voice
        // notes, the gallery's failed-upload tiles rendering the ex-partner's
        // photograph straight off disk) was skipped for exactly the case it
        // was written for. Awaited, because everything after this returns.
        if (knownCoupleId != null) await endCouple(knownCoupleId);
        // Only ever asked for when there is no couple. A paired account has
        // nothing to restore and the server would answer null for it anyway,
        // so this is a round trip nobody else pays for. Unawaited: the pairing
        // screen renders without it and the sheet re-reads on open, so a slow
        // answer costs nothing and a failed one shows nothing.
        unawaited(SeveranceState.load());
        // The mirror rule: a ceremony belongs to a LIVING couple, and this
        // account no longer has one.
        UnlinkState.reset();
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
      unawaited(_subscribePresence(coupleId, gen));

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
          // That select is a round trip of its own, taken well past the fence
          // above. The repair below writes the couple id BACK onto the presence
          // row — so a sign-out answering during the select had its teardown
          // undone by this self-healing, which is the one thing it must never
          // heal. Nothing further down belongs to a dead session either.
          if (!_mayPublish(gen)) {
            debugPrint('[session] presence repair abandoned: session ended');
            return;
          }
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
      //
      // Asked again because the repair itself awaits: this is the loudest
      // publish in the function — it tells the server, and the partner's
      // socket, that this handset is live INSIDE that couple, minutes after
      // the user watched the app return to the sign-in screen.
      if (!_mayPublish(gen)) return;
      try {
        await PresenceService.setOnline(coupleId, online: true);
      } catch (_) {}
    } catch (e) {
      // TimeoutException, a dead radio, or the server refusing: the fetch
      // FAILED, which is not the same as fetching a null row. The error is
      // what makes the difference visible (profileLoadFailed) — without it
      // this state looked identical to a brand-new account, and the router
      // sent paired users offline to the blank onboarding form.
      debugPrint('[session] loadProfile failed: $e');
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Derive the couple key. The straggler problem is answered at the WRITE.
  ///
  /// The derive is three round trips and endCouple's teardown is synchronous,
  /// so a sign-out inside those round trips used to drop a key that had not
  /// been parked yet, and the derive then parked the ex-couple's key for the
  /// rest of the process.
  ///
  /// This method used to undo that from out here, gated on a counter. That was
  /// wrong twice over and is gone: a counter can see that THIS session ended,
  /// but not whether the key now parked is its own straggler or a live one a
  /// newer session put there — and dropping the live one is silent plaintext.
  /// [CryptoCore.deriveSharedKey] now refuses to park a key whose derive began
  /// before the last wipe, which is the same question asked where it can
  /// actually be answered, and it covers the four other call sites that never
  /// had a guard at all.
  ///
  /// So there is nothing to undo here. What remains is the reason the call is
  /// unawaited: nobody blocks the session on a key derive.
  Future<void> _primeCoupleKey(int gen) async {
    await CoupleKey.prime(state);
    if (_mayPublish(gen)) return;
    debugPrint('[session] couple key derived after the session ended; '
        'deriveSharedKey refused to park it');
  }

  bool _subscribingPresence = false;

  Future<void> _subscribePresence(String coupleId, int gen) async {
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
      // Removing the old channel is a round trip, and _endSession's own
      // teardown ran inside it: that teardown nulled a handle this method had
      // already taken, so the join below then opened a NEW channel on the
      // ex-couple's id with nothing left holding it — live realtime traffic for
      // a couple the user has left, until the process dies.
      if (!_mayPublish(gen)) {
        debugPrint('[session] presence subscribe abandoned: session ended');
        return;
      }
      _presenceChannel = SupabaseRepository.subscribeToPresence(
        coupleId: coupleId,
        onPartnerUpdate: (p) {
          // The socket outlives every check above by definition. An ex-partner
          // arriving on it must not be written back into the notifier.
          if (!_mayPublish(gen)) return;
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
    if (couple != null) _subscribePresence(couple.id, _generation);
  }

  Future<void> signOut() async {
    // Before either network call. endCouple bumps this too, but it only runs
    // once forgetDevice() and the server sign-out have BOTH answered — two
    // round trips on the user's connection, during which a loadProfile
    // resolving in the background still read a live generation, walked through
    // every check in this class and re-published the couple the user was in
    // the middle of leaving. The fence closes when the user asks, not when the
    // network agrees.
    _generation++;
    // FIRST, and here rather than at the call sites. Two of the four sign-out
    // buttons never called it, so the handset kept a push token on the profile
    // it was leaving: reach-notify went on addressing that couple's Reaches to
    // this device, and the next account signed in on it received them.
    // Unbinding the device is part of ending a session, not a courtesy the
    // caller can forget — and it must happen while the session is still valid,
    // because the token is cleared with an authenticated write.
    // In a finally, not after: the comment below promises the wipe survives a
    // throw, and sequential awaits kept that promise only when nothing threw
    // — a signOut() that died on the way to the server skipped the wipe and
    // left only the signedOut event (which a pre-event throw never fires) to
    // keep the previous couple's bytes off this handset.
    try {
      await FcmService.forgetDevice();
      await SupabaseRepository.signOut();
    } finally {
      // The signedOut event does this too. Called here as well because a
      // sign-out that threw on the way to the server must still not leave the
      // previous couple's bytes on this handset; everything below is
      // idempotent.
      await _endSession();
    }
  }

  /// Everything that must not outlive a COUPLE, however the couple ended.
  ///
  /// Split out of [_endSession] because unpair never reached it. leaveCouple()
  /// ends with refreshSession(), which fires `tokenRefreshed`, not
  /// `signedOut` — so the whole wipe below was wired to an event a breakup
  /// does not raise, and every one of these survived it: the decrypted
  /// photographs on disk, the voice notes, the unsent draft, the ex-partner's
  /// name, and a send queue still armed to deliver whatever was typed during
  /// the fight.
  ///
  /// [coupleId] is a parameter rather than read from [state] because the
  /// caller must capture it BEFORE loadProfile() nulls it, and because
  /// UnreadTally is keyed by it — which is why sign-out could never clear that
  /// one and still cannot. Null is tolerated: everything else here is
  /// couple-agnostic and must still run.
  Future<void> endCouple(String? coupleId) async {
    // First, before anything is torn down: a load still in flight for the
    // couple being ended must not publish it back over everything below.
    _generation++;
    // And immediately after it, before the first await that could strand it:
    // the row every push on this handset is checked against. It is the only
    // piece of teardown state that lives outside this isolate — the FCM
    // background isolate reads it from disk, where none of the in-memory
    // clears below exist — so a couple left standing in it goes on admitting
    // that couple's queued pushes long after the app has forgotten everything
    // else about them. Verified rather than assumed, because a removal that
    // silently did not happen looks identical from in here to one that worked;
    // that is precisely how the row outlived four earlier teardown paths.
    if (!await SessionScope.forgetCouple()) {
      ErrorReporter.report(
        StateError('active_couple_id survived endCouple'),
        StackTrace.current,
        kind: 'session-scope',
      );
    }
    final ch = _presenceChannel;
    _presenceChannel = null;
    if (ch != null) {
      try {
        await SupabaseService.client.removeChannel(ch);
      } catch (_) {}
    }
    // What the partner was last TOLD about our room. The observer is built once
    // per process (router.dart) and nothing invalidates it, so its dedupe
    // outlived the identity that filled it: the first room the next account
    // lands on matched the last room this one published and was skipped — no
    // current_screen for the new couple, no broadcast, until that user happened
    // to navigate somewhere else. Signing out from the drawer makes it certain
    // rather than unlucky, because the drawer is not a route and the shell's
    // tab is still whatever it was.
    presenceRouteObserver?.reset();
    // And the last thing the socket said about the partner's liveness. It is
    // kept ordered by the SENDER's clock, so a hint left behind by this couple
    // silently swallows the first arrivals of the next one until that person's
    // clock passes it.
    PresenceService.resetLiveHint();
    // Same rule, same clock problem, for the last mood the socket carried.
    PresenceService.resetMoodHint();
    // Both are process-scoped and outlive the couple: a map of live signed
    // URLs to this couple's storage objects, and uploads accepted for it.
    // Neither belongs to whoever this account pairs with next.
    MediaUrls.clear();
    MapToken.clear();
    // Not merely stale — ARMED. A message typed during the argument and left
    // unsent would retry minutes after the user walked away, delivering it to
    // a couple they have just ended.
    ChatSendQueue.instance.clear();
    // Keyed by couple topic. A `dead` left by this couple's channels would
    // otherwise show the next account a permanent "live updates paused".
    RealtimeStatus.reset();
    // Same reason, and one more: the reaction outbox keeps an armed backoff
    // timer, so a reaction left unsent would have retried later under
    // whichever session came next. Its disk copy survives on purpose — it is
    // ciphertext under this account's own key, and signing back in restores it.
    ChatReactionOutbox.instance.endSession();
    // The gallery's failed-upload tiles render the picked file straight from
    // disk — the ex-partner's photograph, still on screen, if this is skipped.
    GalleryScreen.clearFailedUploads();
    // The unsent draft goes with them. It is a message body — the most personal
    // thing in the app — and it survives a screen change on purpose, which
    // means without this it survives the breakup too.
    unawaited(ChatDraftStore.clearAll());
    // Ciphertext too, unlike a cover raise. Raising the cover keeps the disk
    // layer because it is unreadable without the key and re-fetching it every
    // time someone glances at their phone is a great deal of traffic for
    // nothing; ending a couple is different, because the key that opens it is
    // being dropped in the same breath.
    unawaited(EncryptedMediaCache.clearAll());
    // And the PLAINTEXT layer beside it, which nothing ever emptied. Chat
    // photos and gallery images render through CachedNetworkImage, so the
    // decrypted bytes sit in flutter_cache_manager's store under stable keys —
    // readable at the filesystem level long after the couple is gone.
    unawaited(DefaultCacheManager().emptyCache());
    // And the store those photos actually live in now. Chat and gallery moved
    // off the 200-object singleton — that cap was evicting a couple's own
    // gallery while they scrolled it — so emptying only the singleton would
    // leave every picture on disk under a stable key.
    unawaited(PlainMediaCache.clearAll());
    // The grid's remembered list beside them: it names the couple's storage
    // paths, and MediaUrls still holds live 24-hour URLs for every one.
    GalleryRepository.forgetSnapshots();
    // And the third store beside those two. Voice notes are audio of the two of
    // them talking, kept on disk so the waveform can be scrubbed without a
    // range request per drag.
    unawaited(VoiceNoteCache.clearAll());
    imageCache
      ..clear()
      ..clearLiveImages();
    // A push that arrived for the couple that just ended. Left standing it
    // opens their memory on the next first frame.
    pendingMemory.value = null;
    // The partner's NAME, device-scoped: love notes were auto-addressed with
    // it, so without this the next relationship inherits the last one's.
    unawaited(LoveNoteRecipient.clear());
    // The badge count for a couple that no longer exists. Keyed by coupleId,
    // which is the whole reason this method takes one — _endSession never had
    // the id to hand and so has never cleared this, on any path.
    if (coupleId != null) unawaited(UnreadTally.clear(coupleId));
    // The shared key and the retired-key ring, and the epoch bump that makes
    // the plaintext caches CLEAR rather than re-key. Not forgetAccount(): this
    // account is still signed in, still owns its seed, and still needs
    // `keyless` to answer honestly for the /rewrap gate.
    //
    // PartnerKeyPin is deliberately NOT cleared here. It looks like leftover
    // state and it is not: it is the only record that would make a genuine key
    // substitution visible if these two accounts pair again. Clearing it
    // silently downgrades the pair back to trust-on-first-use.
    CryptoCore.forgetPartner();
    // And the memoized derive VERDICT beside the key itself. forgetPartner
    // nulls the key, but CoupleKey holds a completed future that keeps
    // answering for the couple that left — so the next pairing would run with
    // encryption silently off until process death.
    CoupleKey.reset();
  }

  /// Everything that must not outlive a session, however it ended.
  Future<void> _endSession() async {
    // The couple always ends with the session. The reverse is not true, which
    // is the entire reason these are two methods.
    await endCouple(state.couple?.id);
    // The keypair is process-scoped too, and every decrypted byte still held
    // anywhere belongs to the account that just left. The account's sealed
    // seed stays in storage — signing back in must work offline, and for
    // anyone without an escrow row it is the only copy. Bumps the epoch a
    // second time after endCouple; the caches are already empty, so it costs
    // nothing and keeps this correct if it is ever called alone.
    CryptoCore.forgetAccount();
    // Process-scoped answers about the account that just left. Left standing,
    // the next person to sign in on this handset walks past a terms gate they
    // never saw and inherits a pause they never set. Neither belongs in
    // endCouple: a mute is per-user-per-kind, not per-couple, and a pause that
    // silently lifted itself at the moment of a breakup is exactly backwards.
    TermsGate.reset();
    ContactPause.reset();
    // The chat page cache holds DECRYPTED messages so a tab switch does not
    // cost a spinner and a round trip. It is process-scoped and keyed by
    // couple, but it belongs to the account that just left and has no business
    // outliving it.
    ChatRepository.forget();
    // Set true when THIS account published a key over a different one, and it
    // was only ever set. Left standing, account B signing in on the same
    // handset inherited account A's permanent "can't be opened here — or on
    // hers" wording over content of B's that opens perfectly.
    SupabaseRepository.keyWasReplaced = false;
    // Describes a couple THIS account used to be in. Left standing, the next
    // person to sign in on this handset is told about somebody else's breakup.
    SeveranceState.reset();
    UnlinkState.reset();
    state = const SessionState(loading: false);
    // The device unbind, and here rather than only in signOut(). A session the
    // SERVER ended — a revoked or expired refresh token, or "sign out other
    // devices" — arrives as an event and never passes through signOut(), so
    // this handset kept the previous account's couple in SessionScope and the
    // previous account's Reach sitting in pendingReach: that couple's pushes
    // were still admitted while the phone sat signed out, and the next account
    // to sign in popped the last one's overlay with an ex-partner's name on it.
    //
    // The server half of the unbind cannot run from here — nulling
    // profiles.fcm_token is an authenticated write and there is no session left
    // — and forgetDevice already tolerates that: setFcmToken returns without
    // writing when there is no user. The local half is what is being claimed,
    // and it is the half that was missing.
    //
    // Last and unawaited, after the state is published. The parts that matter
    // here — the pending notifiers and the stored couple — are set before it
    // touches the network, and the one slow step, deleting the FCM token, is
    // something no caller waits on: signOut() already awaited its own
    // authenticated pass, and a sign-out that hangs on a dead radio is how a
    // user ends up force-killing the app instead of leaving it. forgetDevice
    // reports its own failures rather than throwing.
    unawaited(FcmService.forgetDevice());
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
