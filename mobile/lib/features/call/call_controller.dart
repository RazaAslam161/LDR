import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
// A src/ import, deliberately: the plugin's global event stream is public in
// behaviour but not re-exported, and the vendored fork (see pubspec) is pinned
// so the path cannot drift under us.
import 'package:flutter_webrtc/src/native/event_channel.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/features/call/pip_mode.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/features/call/call_foreground.dart';
import 'package:miles/features/call/call_stats.dart';
import 'package:miles/features/call/screen_share_session.dart';
import 'package:miles/features/safety/contact_pause.dart';
import 'package:miles/main.dart' show MilesApp;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum CallState { idle, calling, ringing, connected, ended }

/// 1:1 video calling over WebRTC, with signalling carried on a Supabase realtime
/// broadcast channel (`call:<coupleId>`): offer / answer / ice / hangup.
///
/// v1 rings only while both apps are foreground (the offer itself is the ring).
/// Background ringing (FCM full-screen intent) reuses the Reach pipeline later.
class CallController extends ChangeNotifier {
  CallController(this._ref);
  final Ref _ref;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  /// The partner's shared display, on its own connection and so its own
  /// renderer. Separate from [remoteRenderer] because both arrive at once: a
  /// share never costs you their face.
  final RTCVideoRenderer screenRenderer = RTCVideoRenderer();

  /// My own outgoing share, for the self-preview — bound whenever a share is
  /// live, DRAWN only when [appScopedShare] says the capture excludes this
  /// app (previewing a whole-display share is a mirror inside the pixels
  /// being captured, which recurses).
  final RTCVideoRenderer screenSelfRenderer = RTCVideoRenderer();

  /// True once Android has reported a captured-content size smaller than the
  /// display: the user picked "One app" in the Android 14 picker. Never set
  /// on older Android — the event does not exist there.
  bool appScopedShare = false;
  StreamSubscription<Map<String, dynamic>>? _webrtcEventsSub;

  RealtimeChannel? _chan;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  /// The share's own dedicated peer connection — the sharer's send side or the
  /// receiver's receive side, whichever this device is. Null when no share is
  /// up. The call's connection never carries a display; see
  /// [ScreenShareSession] for why.
  ScreenShareSession? _shareSession;

  /// The display capture, separate from [_localStream] and ours to dispose. The
  /// camera track stays alive inside _localStream throughout, so stopping a
  /// share is a swap back rather than a fresh getUserMedia.
  MediaStream? _screenStream;
  String? _coupleId;
  String? _myUid;

  CallState state = CallState.idle;
  bool isCaller = false;
  bool micOn = true;
  bool camOn = true;
  bool isVideo = true; // false = voice-only call
  bool speakerOn = true; // video starts on the speaker, voice at the ear

  /// What the call is actually doing. Null until the first sample lands.
  CallStats? stats;
  late final CallStatsMonitor _statsMonitor = CallStatsMonitor((s) {
    stats = s;
    notifyListeners();
  });
  bool frontCamera = true; // drives the local preview mirror
  bool minimized = false; // call screen dismissed but call still running
  bool sharingScreen = false; // my display is going out in place of my camera
  bool remoteScreen = false; // theirs is ON MY SCREEN — real pixels arrived

  /// They ANNOUNCED a share; it has not necessarily arrived.
  ///
  /// These were one flag, and that was the black screen. `screen{on:true}` is
  /// broadcast before the offer is even created, so the instant it landed the
  /// big view swapped to an empty screenRenderer and the partner's face was
  /// gone — whether or not the share ever negotiated, with nothing to put it
  /// back. Announcement drives the "they are sharing" affordances; only real
  /// pixels ([remoteScreen], set from onRemoteStream) may take the big view.
  bool remoteSharePending = false;

  /// Share ICE that arrived before the receive session existed.
  ///
  /// _receiveShare can take hundreds of milliseconds to publish _shareSession
  /// (stopScreenShare -> dropScreenShare polls the foreground service for up
  /// to 500ms), and the sharer's candidates arrive within a few ms of the
  /// offer. They were being dropped on the floor in exactly that window, which
  /// can cost the whole host candidate set. Bounded: a share that needs more
  /// than this is not going to connect on the ones after it either.
  final List<Map<dynamic, dynamic>> _pendingShareIce = [];
  static const int _maxPendingShareIce = 64;

  /// Serialises _receiveShare against itself. It is invoked unawaited from the
  /// signal switch, so two offers in flight ran two concurrent bodies, the
  /// second closing the first's session while the first was suspended inside
  /// onOffer — then operating on a disposed connection.
  Future<void> _receiveGate = Future<void>.value();
  String? peerName; // who's calling / being called

  final List<RTCIceCandidate> _pendingRemote = [];
  final List<RTCIceCandidate> _localCandidates =
      []; // re-sent if callee was closed
  bool _remoteSet = false;
  Timer? _connectTimer;

  /// Shared by both devices for one call, so their traces can be laid side by
  /// side. It is also the `call_invites` row id, deliberately: the callee that
  /// was woken by FCM never saw the broadcast, so the invite id is the ONLY
  /// thing it and the caller both hold.
  String? _callId;

  /// Which attempt owns the fields below.
  ///
  /// Bumped by _teardown and by a glare resolution, and captured across every
  /// await on a call path. Without it a resolution that lands while startCall
  /// is between _openMedia and _startConnectTimeout lets the dead attempt run
  /// to completion: it publishes its peer connection over _pc, and the one it
  /// displaced is left holding an OPEN MICROPHONE that nothing will ever close
  /// — _teardown disposes the field, not the orphan, so the leak outlives the
  /// call, the call screen, and the next call as well.
  int _attempt = 0;

  /// True for the whole of a _teardown, which is four awaits long.
  ///
  /// `state` is not written until the last of them, so until then this
  /// controller still reads `calling` with isCaller true — the exact shape the
  /// glare branch adopts on, and the shape dispose()'s own Closed callback
  /// re-enters _teardown with.
  bool _tearingDown = false;

  /// The call id this device is in the middle of adopting, or null.
  ///
  /// Open only from the moment the peer's offer wins the tie-break until
  /// _callId becomes theirs. Signals are demuxed by call_id, and for the width
  /// of that window the peer's candidates are addressed to an id this device
  /// does not answer to yet — they are early, not stale.
  String? _resolvingCallId;

  /// Candidates that arrived under [_resolvingCallId] before it was adopted.
  ///
  /// Buffered rather than dropped. Dropped, the adopted call begins with no
  /// remote candidates at all, which is indistinguishable in every trace from
  /// signalling that never arrived — one of the two failures this file already
  /// spends a hundred lines separating.
  final List<Map<String, dynamic>> _resolvingIce = [];

  /// The capture a call attempt has already asked the platform for.
  ///
  /// Android opens one camera per process, and getUserMedia is the widest await
  /// on the call path — so it is the await a glare resolution most often lands
  /// inside. A second request while the first is in flight either throws (busy)
  /// or leaves two live captures with one of them stranded; the adoption waits
  /// for this one instead.
  Future<MediaStream>? _openingMedia;

  /// The unawaited invite insert, so a call that is abandoned can delete its
  /// row after the insert it is racing has actually landed.
  Future<void>? _inviteWrite;

  /// Candidate types seen, ours and theirs. The counts are the whole diagnosis
  /// when a call fails: no local relay means TURN never allocated, no remote
  /// candidates at all means signalling never arrived, and both present with no
  /// pairing means the network dropped the media itself. Those are three
  /// different bugs that produce one identical screen.
  final Map<String, int> _localCandTypes = {};
  final Map<String, int> _remoteCandTypes = {};

  /// When this attempt began, so every later event carries its own age. "The
  /// call failed" and "the call failed 34 seconds in, one second before the
  /// timeout" are the same sentence at different resolutions, and only the
  /// second one points anywhere.
  DateTime? _startedAt;

  /// Re-subscribe the call channel after the realtime socket is reset (e.g. on
  /// app resume / Android doze) so incoming calls keep ringing.
  Future<void> reconnect() => _subscribeChannel();

  bool _subscribingChan = false;

  /// Whether the last subscribe actually reached SUBSCRIBED. Every offer,
  /// answer and candidate rides this one channel, so this is the difference
  /// between a call that can happen and one that sits on "Calling…" for 35
  /// seconds and then reads as a network fault.
  bool _chanLive = false;
  int _subscribeAttempt = 0;
  Timer? _resubscribeTimer;

  /// (Re)subscribe `call:<coupleId>` cleanly — Pattern A: await removeChannel(old)
  /// before re-creating, so a reconnect never leaves a duplicate-topic channel
  /// joined-but-dead (which would silently drop incoming offer/answer/ice/hangup).
  Future<void> _subscribeChannel() async {
    final id = _coupleId;
    if (id == null || _subscribingChan) return;
    _subscribingChan = true;
    _resubscribeTimer?.cancel();
    _chanLive = false;
    try {
      final old = _chan;
      _chan = null;
      if (old != null) {
        try {
          await SupabaseService.client.removeChannel(old);
        } catch (_) {}
      }
      final topic = 'call:$id';
      // The status was thrown away here. Every signal this app sends goes over
      // this one channel, so a subscribe that lands in CHANNEL_ERROR or
      // TIMED_OUT means no offer, no answer, no ICE and no hangup ever moves —
      // and _send below drops them without a word. The call then fails at the
      // 35s timeout looking exactly like a network problem, which is where two
      // months of diagnosis went.
      _chan = SupabaseService.client
          .channel(topic, opts: RealtimeChannelConfig(private: true))
          .onBroadcast(event: 'signal', callback: _onSignal)
          .subscribe((status, err) {
        // A subscribe callback outlives the channel that owns it: after a
        // rebind the PREVIOUS couple's channel still reports, and letting it
        // write _chanLive is how a dead topic passes for a live one.
        if (id != _coupleId) return;
        final live = status == RealtimeSubscribeStatus.subscribed;
        _chanLive = live;
        // The topic, because it is the one link a failing trace could not read:
        // a channelError on the couple you LEFT and one on your own couple are
        // the same row otherwise, and they are different bugs. The channel is
        // private, so the topic is what the RLS policy on realtime.messages is
        // actually judging.
        Diag.record(DiagArea.call, 'signal_subscribe', corr: _callId, fields: {
          'status': status.name,
          'topic': topic,
          'attempt': _subscribeAttempt,
          if (err != null) 'error': err.runtimeType.toString(),
        },);
        if (live) {
          _subscribeAttempt = 0;
          // Re-announce a share that is already running. `screen` is a
          // fire-and-forget broadcast with no ack: if the one that announced
          // this share was sent while the channel was down, the partner is
          // cropping a portrait display and there was previously nothing that
          // would ever correct it. Cheap, idempotent, and only sent on a call
          // that is actually sharing.
          if (sharingScreen && state == CallState.connected) {
            _send('screen', {'on': true});
          }
        } else {
          _scheduleResubscribe();
        }
      });
    } finally {
      _subscribingChan = false;
    }
  }

  /// A refused subscribe used to sit dead for the life of the process: nothing
  /// retried it, and every later call spent its full timeout sending into a
  /// channel the server had already closed. Backed off, because the denial can
  /// be permanent (a wrong topic) and a tight loop on it is a reconnect storm.
  void _scheduleResubscribe() {
    if (_coupleId == null) return;
    _resubscribeTimer?.cancel();
    final delay = Duration(seconds: 1 << _subscribeAttempt.clamp(0, 4));
    _subscribeAttempt++;
    _resubscribeTimer = Timer(delay, () {
      if (!_chanLive) unawaited(_subscribeChannel());
    });
  }

  /// Wait, briefly, for signalling to be live before a call is allowed to
  /// depend on it. Bounded: someone is holding the phone.
  Future<bool> _ensureChannel() async {
    if (_chanLive) return true;
    // Nothing to subscribe to. Waiting out the budget would only delay the
    // message.
    if (_coupleId == null) return false;
    _subscribeAttempt = 0;
    await _subscribeChannel();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!_chanLive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return _chanLive;
  }

  /// Refuse a call that has nowhere to signal, and say so.
  ///
  /// Placing it anyway is what produced 228 sends that went nowhere, six
  /// invites refused, and a 35s wait that told the user nothing.
  void _failWithoutChannel(String event) {
    Diag.record(DiagArea.call, event, corr: _callId, fields: {
      'couple': _coupleId,
      'attempt': _subscribeAttempt,
    },);
    _lastError = 'Calling is not connected right now. '
        'Check your connection and try again in a moment.';
    unawaited(_teardown(CallState.ended));
  }

  /// If the peer connection doesn't connect within a window, stop hanging on
  /// "Calling…"/"Connecting…" and end the call cleanly.
  void _startConnectTimeout() {
    _connectTimer?.cancel();
    _connectTimer = Timer(const Duration(seconds: 35), () {
      if (state != CallState.connected) {
        // Everything needed to explain the failure, in one row, at the moment
        // it is known to have failed. Reading it: no remote candidates at all
        // means signalling never arrived; no local relay means TURN never
        // allocated; both present means the media path itself was blocked.
        Diag.record(DiagArea.call, 'connect_timeout', corr: _callId, fields: {
          'state': state.name,
          'local_host': _localCandTypes['host'] ?? 0,
          'local_srflx': _localCandTypes['srflx'] ?? 0,
          'local_relay': _localCandTypes['relay'] ?? 0,
          'remote_host': _remoteCandTypes['host'] ?? 0,
          'remote_srflx': _remoteCandTypes['srflx'] ?? 0,
          'remote_relay': _remoteCandTypes['relay'] ?? 0,
          'remote_set': _remoteSet,
          'turn_error': turnError == null,
        },);
        // The screen pops itself the moment state returns to idle, so a call
        // that ran the full 35 seconds and died used to leave nothing at all
        // behind — the same blank as a call that was simply declined.
        _lastError = _remoteCandTypes.isEmpty
            ? 'Your partner never answered — their app may be closed.'
            : 'Could not connect the call. One of you may be on a network '
                'that blocks calls.';
        _send('hangup', {});
        _teardown(CallState.ended);
      }
    });
  }

  /// Store the offer durably so a CLOSED callee can still answer; the insert
  /// trigger fires the FCM ring.
  ///
  /// That trigger is `notify_call`, and it POSTs to reach-notify — not to the
  /// call-notify function this comment used to name. call-notify was deployed
  /// once, wired to nothing, and left running unauthenticated for a year.
  ///
  /// The id is a parameter, not a read of `_callId`: this method awaits, and a
  /// glare resolution landing inside it would otherwise file the row under the
  /// WINNER's id — whose own insert then fails on the primary key, and that
  /// insert is the push, which is the only thing that wakes a closed app.
  Future<void> _insertInvite(String id, String offerSdp, bool video) async {
    final couple = _coupleId;
    final me = _myUid;
    final callee = _ref.read(sessionProvider).partner?.id;
    if (couple == null || me == null || callee == null) {
      // Returned in silence. The FCM ring hangs entirely off this insert, so
      // this is "the callee's phone never made a sound" — and the caller's
      // screen is identical to a call that rang and went unanswered.
      Diag.record(DiagArea.call, 'invite_skipped', corr: id, fields: {
        'has_couple': couple != null,
        'has_me': me != null,
        'has_callee': callee != null,
      },);
      return;
    }
    try {
      await SupabaseService.client.from('call_invites').insert({
        // Explicit, so the row id IS the call id and the FCM-woken callee joins
        // the same trace as the caller.
        'id': id,
        'couple_id': couple,
        'caller_id': me,
        'callee_id': callee,
        'offer_sdp': offerSdp,
        'video': video,
      });
      Diag.record(DiagArea.call, 'invite_inserted', corr: id);
    } catch (e) {
      // `catch (_) {}` before. This insert is what fires the push that rings a
      // closed app, so when it fails the caller waits the full 35s and tears
      // down with no reason to show.
      //
      // The class alone is not a diagnosis, and recording only the class cost a
      // field test: a fresh couple failed here six times out of six, and an RLS
      // denial (42501), a stale PostgREST schema cache (PGRST204) and a
      // duplicate id are one indistinguishable "PostgrestException" without the
      // code. Same two fields as msg_insert_result, so both write paths read
      // alike.
      Diag.record(DiagArea.call, 'invite_failed', corr: id, fields: {
        'error': e.runtimeType.toString(),
        // Which couple the row was written FOR. A 42501 here is the RLS policy
        // saying this is not your couple — unreadable without knowing which
        // couple was tried, and that is precisely how a controller holding the
        // previous account's id stayed invisible.
        'couple': couple,
        'pg_code': e is PostgrestException ? e.code : null,
        'pg_msg': e is PostgrestException ? e.message : null,
      },);
    }
  }

  /// Take back the durable invite for a call that was abandoned.
  ///
  /// A glare resolution always leaves one: the yielding device inserted its own
  /// row, and the trigger on that insert has already pushed the partner. Left
  /// behind, it is a phone that rings for a call nobody is placing — on a push
  /// delivered late out of doze, or on a notification tapped after a restart —
  /// and handlePendingCall checks only that the row exists.
  Future<void> _deleteInvite(String id) async {
    try {
      await SupabaseService.client.from('call_invites').delete().eq('id', id);
      Diag.record(DiagArea.call, 'invite_deleted', corr: id);
    } catch (e) {
      Diag.record(DiagArea.call, 'invite_delete_failed', corr: id, fields: {
        'error': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
      },);
    }
  }

  /// Ring a call delivered by FCM (the realtime offer was likely missed because
  /// the app was closed). Fetch the stored offer and present it as ringing.
  Future<void> handlePendingCall(
      String callId, String fromName, bool fallbackVideo,) async {
    if (state != CallState.idle || callId.isEmpty) return;
    // notify_call already refuses to send this push while the pause is on, so
    // reaching here means a payload that outlived the pause being set — a push
    // delivered late, or one sitting in pendingCall from before the app was
    // resumed. Ringing off a stale payload is the same interruption by a
    // slower route.
    if (ContactPause.isActive) {
      Diag.record(DiagArea.call, 'pending_call_paused', corr: callId);
      return;
    }
    unawaited(reconnect()); // make sure the call channel is live for the answer + ICE
    try {
      final row = await SupabaseService.client
          .from('call_invites')
          .select()
          .eq('id', callId)
          .maybeSingle();
      final sdp = row?['offer_sdp'] as String?;
      if (sdp == null || sdp.isEmpty || state != CallState.idle) return;
      // The invite row id IS the call id, so a callee woken by FCM files its
      // trace under the same name as the caller who never saw it ring.
      _callId = callId;
      _ring(
        RTCSessionDescription(sdp, 'offer'),
        video: (row?['video'] as bool?) ?? fallbackVideo,
        from: fromName,
      );
      Diag.record(DiagArea.call, 'pending_call_rang', corr: callId);
    } catch (e) {
      // The whole FCM ring path, silent. An RLS denial or a deleted row here
      // means the phone buzzed and then nothing happened — which the user
      // reports as a missed call, not as an error.
      Diag.record(DiagArea.call, 'pending_call_failed', corr: callId, fields: {
        'error': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
        'pg_msg': e is PostgrestException ? e.message : null,
      },);
    }
  }

  // ── ICE / TURN ─────────────────────────────────────────────────────────────
  static List<Map<String, dynamic>> _cachedTurn = [];
  static DateTime? _turnFetchedAt;

  /// When the last fetch failed, so a broken relay does not cost every call the
  /// full timeout.
  static DateTime? _turnFailedAt;

  /// Short-lived Cloudflare TURN ICE servers, minted by the `turn-credentials`
  /// edge function (the Cloudflare API token stays server-side, never in the
  /// app). Cached ~12h (the creds live 24h). Best-effort: on any failure we
  /// return whatever is cached (possibly nothing) and the call still connects on
  /// permissive networks via STUN.
  static const _turnCacheKey = 'turn_ice_servers';
  static const _turnCacheAtKey = 'turn_ice_servers_at';

  /// Load the last known-good relay from disk.
  ///
  /// Credentials live 24h, so the previous fetch is almost always still valid.
  /// Without this, every cold start depends on a fresh network round trip
  /// completing before the first call — and on a slow mobile network that is
  /// exactly when it does not. A user whose fetch times out was left with no
  /// relay at all and no way to know.
  static Future<void> loadCachedTurn() async {
    if (_cachedTurn.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_turnCacheKey);
      final at = prefs.getInt(_turnCacheAtKey);
      if (raw == null || at == null) return;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      // Minted with a 24h TTL; refuse anything close to the edge.
      if (age > const Duration(hours: 20).inMilliseconds) return;
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(Map<String, dynamic>.from)
          .toList();
      if (list.any(_isRelay)) {
        _cachedTurn = list;
        _turnFetchedAt =
            DateTime.fromMillisecondsSinceEpoch(at);
        debugPrint('[turn] restored ${list.length} server(s) from disk');
      }
    } catch (e) {
      debugPrint('[turn] cache restore failed: $e');
    }
  }

  static Future<void> _persistTurn(List<Map<String, dynamic>> servers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_turnCacheKey, jsonEncode(servers));
      await prefs.setInt(
          _turnCacheAtKey, DateTime.now().millisecondsSinceEpoch,);
    } catch (_) {
      // A cache that fails to save is not worth failing a call over.
    }
  }

  static Future<List<Map<String, dynamic>>> _turnServers() async {
    final at = _turnFetchedAt;
    if (at != null &&
        _cachedTurn.isNotEmpty &&
        DateTime.now().difference(at) < const Duration(hours: 12)) {
      return _cachedTurn;
    }
    // The backoff protects background refreshes from hammering a broken
    // function. It must NOT apply when someone is placing a call and we have no
    // relay at all — that is a first install whose one fetch happened to fail,
    // and refusing to retry would hand them a call that cannot possibly connect.
    // The backoff exists to stop a broken function being hammered. It used to
    // be guarded on `_cachedTurn.isNotEmpty`, which disabled it in exactly the
    // case it was written for: nothing cached and the function failing. That
    // turned every call into repeated 15s timeouts.
    final failedAt = _turnFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 60)) {
      // Backing off is correct and is also why a call placed right after a
      // failed fetch has no relay. Without this line that call looks like TURN
      // was never configured at all.
      Diag.record(DiagArea.call, 'turn_backoff',
          fields: {'cached': _cachedTurn.length},);
      return _cachedTurn;
    }
    final endFetch = Diag.span(DiagArea.call, 'turn_fetch');
    try {
      final res = await SupabaseService.client.functions
          .invoke('turn-credentials')
          // 8s is not enough on a slow mobile network, and this runs while the
          // user is waiting to place a call.
          .timeout(const Duration(seconds: 15));

      final data = res.data;
      final raw = data is Map ? data['iceServers'] : null;
      // Cloudflare returns iceServers as a single OBJECT, not an array. This
      // used to demand a List and bail — so the cache stayed empty forever, no
      // relay ever reached a peer connection, and every call between two
      // networks failed while two phones on one wifi worked fine on host
      // candidates. The edge function normalises this now; accepting both
      // shapes here too means a stale deployed function cannot resurrect it.
      final List<dynamic> rawList;
      if (raw is List) {
        rawList = raw;
      } else if (raw is Map) {
        rawList = [raw];
      } else {
        turnError = 'bad response shape';
        endFetch(outcome: 'bad_shape', fields: {'got': raw.runtimeType.toString()});
        debugPrint('[turn] unexpected response: ${data.runtimeType} $data');
        return _cachedTurn;
      }

      final parsed = <Map<String, dynamic>>[];
      for (final srv in rawList) {
        if (srv is! Map) continue;
        final m = Map<String, dynamic>.from(srv);
        final urls = m['urls'];
        if (urls is List) m['urls'] = urls.map((e) => e.toString()).toList();
        parsed.add(m);
      }
      // A response with only STUN entries is NOT a working relay. Counting it
      // as success is how a misconfigured project looks healthy right up until
      // two users are on different networks.
      final relays = parsed.where(_isRelay).length;
      if (relays == 0) {
        turnError = 'no relay in response';
        endFetch(outcome: 'no_relay', fields: {'servers': parsed.length});
        debugPrint('[turn] response carried ${parsed.length} servers but no '
            'turn:/turns: entry — relay is NOT available');
        return _cachedTurn;
      }

      _cachedTurn = parsed;
      _turnFetchedAt = DateTime.now();
      turnError = null;
      endFetch(outcome: 'ok', fields: {'relays': relays, 'servers': parsed.length});
      unawaited(_persistTurn(parsed));
      debugPrint('[turn] ok — $relays relay server(s)');
      return parsed;
    } on FunctionException catch (e) {
      // Anything non-2xx lands here — functions_client throws rather than
      // returning (functions_client.dart:183-190), so the failure body arrives
      // as `details`, not as res.data. This is where 'turn_not_configured'
      // (secrets missing) and 'cloudflare_error' (bad token) actually surface.
      turnError = 'HTTP ${e.status}: ${e.details}';
      debugPrint('[turn] edge function failed — $turnError');
    } on TimeoutException {
      turnError = 'timeout';
      debugPrint('[turn] credential fetch timed out');
    } catch (e) {
      turnError = '$e';
      debugPrint('[turn] credential fetch failed: $e');
    }
    // Back off after a failure. Without this, a broken function makes EVERY
    // call wait the full timeout before the offer is even sent — the fetch sits
    // in front of _createPc, so the user pays for it on every attempt.
    _turnFailedAt = DateTime.now();
    return _cachedTurn;
  }

  static bool _isRelay(Map<String, dynamic> server) {
    final u = server['urls'];
    final all = u is List ? u.join(' ') : '$u';
    return all.contains('turn:') || all.contains('turns:');
  }

  /// Why the last relay fetch failed, or null when relay is available.
  ///
  /// Exposed rather than swallowed: without a relay, two users behind different
  /// carrier NATs simply cannot connect, and every symptom of that looks like
  /// "the call did not work". This is the difference between that sentence and
  /// an actionable report.
  static String? turnError;

  /// Why the last call attempt failed. Consumed once by the call screen as it
  /// pops, so a stale reason cannot resurface on the next call.
  String? _lastError;

  String? takeLastError() {
    final e = _lastError;
    _lastError = null;
    return e;
  }

  /// Whether the last ICE config actually contained a relay.
  /// Derived from the cache, not from a side effect of building a peer
  /// connection. It used to be a static assigned only inside _iceConfig, so on
  /// the callee — which rings before it ever builds one — it read false
  /// unconditionally and showed a scary "no relay" banner on a perfectly
  /// healthy device, while the one diagnostic built to distinguish a relay
  /// problem from everything else reported the wrong answer.
  static bool get relayAvailable => _cachedTurn.any(_isRelay);

  /// Null until a fetch has been attempted in this process — "unknown" is not
  /// the same as "no", and the UI should not accuse the network before asking.
  static bool? get relayKnown =>
      (_turnFetchedAt == null && _cachedTurn.isEmpty) ? null : relayAvailable;

  /// Full WebRTC ICE config: Google/Cloudflare STUN + Cloudflare TURN (which
  /// includes TURN-over-TLS:443 for carrier-NAT / UDP-blocked networks). A static
  /// TURN from .env (METERED_TURN_*) is appended if present, as a manual override.
  /// Make sure a relay is available before a call goes out.
  ///
  /// A fresh install has nothing cached, so its FIRST call depends entirely on
  /// one network fetch landing. On mobile data against a cold edge function
  /// that is exactly the fetch most likely to miss — and a new user's first
  /// impression is a call that cannot connect. Retried once, briefly, because a
  /// person is waiting.
  /// One shared fetch. Concurrent callers await the same request instead of
  /// serialising their own, which is what turned a cold cache into three
  /// sequential 15s round trips.
  static Future<List<Map<String, dynamic>>>? _inflightTurn;

  static Future<List<Map<String, dynamic>>> _sharedTurnFetch() {
    final existing = _inflightTurn;
    if (existing != null) return existing;
    final f = _turnServers().whenComplete(() => _inflightTurn = null);
    _inflightTurn = f;
    return f;
  }

  /// Best-effort relay warm-up with a HARD wall-clock budget.
  ///
  /// This used to retry unbounded, twice, at 15s each, in front of createOffer
  /// — 45s before the callee's phone rang, against the caller's own 35s
  /// timeout. The call was mathematically guaranteed to fail. A call is worth
  /// waiting a few seconds for; past that the offer goes out with whatever is
  /// known and relay candidates arrive by trickle, which is how ICE is
  /// designed to work.
  ///
  /// Except that trickle is a half-truth here, and the half that is false is
  /// the one a NEW device lands on: `iceServers` are read once, when the peer
  /// connection is constructed, and `setConfiguration` is called nowhere in
  /// this file — so credentials that arrive after `_createPc` cannot join this
  /// call at all. A phone with a warm cache loses nothing by a short budget; a
  /// phone with an empty one loses its relay for the whole call, and a fresh
  /// install is exactly the phone with an empty one, fetching from a cold edge
  /// function on mobile data. So the wait is longer when there is nothing to
  /// fall back on — bounded at 10s, which still leaves 25 of the callee's 35.
  static const _warmRelayBudget = Duration(seconds: 3);
  static const _coldRelayBudget = Duration(seconds: 10);

  static Future<void> _ensureRelay() async {
    if (_cachedTurn.any(_isRelay)) return;
    final cold = _cachedTurn.isEmpty;
    final Duration budget = cold ? _coldRelayBudget : _warmRelayBudget;
    final startedAt = DateTime.now();
    // A person pressing Call outranks the backoff. The backoff exists to stop
    // BACKGROUND refreshes hammering a broken function; applied here it made
    // one failed warm-up at launch abort every call for the next 60 seconds
    // without touching the network — worst for a new user on a flaky carrier,
    // whose first attempt is the one most likely to have failed.
    _turnFailedAt = null;
    try {
      await _sharedTurnFetch().timeout(budget);
    } on TimeoutException {
      debugPrint('[turn] relay warm-up exceeded ${budget.inSeconds}s — '
          'proceeding without a relay on this call');
    } catch (e) {
      debugPrint('[turn] relay warm-up failed: $e');
    }
    // How long the person waited, and whether the wait bought a relay. On a
    // first-ever call this is the difference between "TURN is misconfigured"
    // and "the fetch was slower than the budget", which look identical from
    // the pc_created row alone.
    Diag.record(DiagArea.call, 'relay_wait', fields: {
      'cold': cold,
      'budget_ms': budget.inMilliseconds,
      'ms': DateTime.now().difference(startedAt).inMilliseconds,
      'relay': relayAvailable,
    },);
  }

  /// Refreshes credentials WITHOUT blocking anything. Called at init and on
  /// resume so a call never pays for the fetch.
  static void warmRelay() {
    if (_cachedTurn.any(_isRelay) && _turnFetchedAt != null) {
      final age = DateTime.now().difference(_turnFetchedAt!);
      if (age < const Duration(hours: 12)) return;
    }
    unawaited(_sharedTurnFetch().catchError((_) => _cachedTurn));
  }

  static Future<Map<String, dynamic>> _iceConfig() async {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ];
    // Synchronous read only. This used to await _turnServers(), so building
    // the peer connection could itself block on a 15s network call, after
    // _ensureRelay had already been awaited — the third of three round trips.
    servers.addAll(_cachedTurn);

    // A second relay provider used to be read from the bundled `.env` here.
    // Those three keys were removed from `.env` in 2026-08 — it ships inside the
    // artifact as a Flutter asset, so anything in it unzips out of the APK — and
    // this read outlived them, quietly resolving to empty on every call since.
    //
    // Dead code that reads a value which no longer exists is worse than no code:
    // it reads as a configured fallback. It cost a later reader several hours on
    // the belief that live credentials were shipping in the binary.
    //
    // `turn-credentials` (v5) now appends Metered from `app_secrets` when the
    // three rows exist, so a second provider arrives through _cachedTurn above
    // with the rest — same fetch, same cache, no second round trip and nothing
    // to read from disk here.

    debugPrint('[turn] ice config: ${servers.length} servers, '
        'relay=${relayAvailable ? 'YES' : 'NO'}'
        '${turnError == null ? '' : ' ($turnError)'}');
    return {'iceServers': servers, 'sdpSemantics': 'unified-plan'};
  }

  bool _inited = false;

  /// Process-scoped setup: the renderers and the relay cache. Nothing here
  /// depends on WHO is signed in — that is [bindSession], which runs again
  /// every time it changes.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    await localRenderer.initialize();
    await screenRenderer.initialize();
    await remoteRenderer.initialize();
    await screenSelfRenderer.initialize();
    // The vendored plugin forwards MediaProjection's callbacks as events —
    // the system "Stop sharing" press, and Android 14's captured-content size.
    _webrtcEventsSub =
        FlutterWebRTCEventChannel.instance.handleEvents.stream.listen(
      _onWebrtcPluginEvent,
    );
    // Disk first so a call placed seconds after launch already has a relay,
    // then refresh in the background. Never awaited on a call path.
    await loadCachedTurn();
    warmRelay();
  }

  /// Point signalling at the account that is signed in NOW.
  ///
  /// This used to happen once, inside `init()`, behind an `if (_inited) return`
  /// — and `_coupleId` was assigned nowhere else in the file. Two consequences,
  /// both fatal and both silent. A first read that beat the couple resolving
  /// left the controller unable to subscribe or send for the rest of the
  /// process. And signing out and back in as a different account kept the
  /// PREVIOUS couple: the channel stayed `call:<old couple>`, which the private
  /// -channel policy on realtime.messages denies, so no signal moved in either
  /// direction; and every durable invite carried the old couple_id and the old
  /// caller_id, so `call_invites` refused it 42501. Both halves of calling,
  /// dead, from one stale field.
  Future<void> bindSession(SessionState s) async {
    final coupleId = s.couple?.id;
    final userId = s.profile?.id;
    final action = callBindingFor(
      authenticated: s.isAuthenticated,
      coupleId: coupleId,
      userId: userId,
      boundCoupleId: _coupleId,
      boundUserId: _myUid,
    );
    if (action == CallBinding.unchanged) return;
    // Kept from the original init(): this event is how a field test tells
    // "calls never work on my phone" from "calls failed this once".
    Diag.record(DiagArea.call, 'init', fields: {
      'action': action.name,
      'has_couple': coupleId != null,
      'has_uid': userId != null,
      'rebind': _coupleId != null && _coupleId != coupleId,
    },);
    if (state != CallState.idle) await _teardown(CallState.ended);
    _resubscribeTimer?.cancel();
    _subscribeAttempt = 0;
    _chanLive = false;
    final old = _chan;
    _chan = null;
    _coupleId = coupleId;
    _myUid = userId;
    if (old != null) {
      try {
        await SupabaseService.client.removeChannel(old);
      } catch (_) {}
    }
    if (action == CallBinding.clear) return;
    await _subscribeChannel();
    warmRelay();
  }

  // ── Outgoing ──────────────────────────────────────────────────────────────
  Future<void> startCall({bool video = true}) async {
    // The `|| _coupleId == null` that used to be here made the Call button do
    // nothing at all — no state change, no row, no message — on exactly the
    // devices where the binding had gone wrong. An unbound controller now fails
    // through the channel gate below, which says so out loud.
    if (state != CallState.idle) return;
    // Claimed before the first await. Everything below resumes on a controller
    // that may have been handed to the PEER's call in the meantime: both people
    // pressed Call, this side lost the tie-break, and every line after that
    // point would otherwise write over the call being rescued.
    final attempt = ++_attempt;
    isCaller = true;
    isVideo = video;
    camOn = video;
    minimized = false;
    peerName = _ref.read(sessionProvider).partner?.displayName ?? 'Partner';
    // Minted here rather than by the database, because it has to be on the
    // broadcast offer AND be the invite row id — those are the two separate
    // paths a callee can learn about this call on, and both traces have to
    // land under one name. It is also this device's operand in the glare
    // tie-break, which is why it is assigned outright: a `??=` here would make
    // two consecutive calls share one id, and a shared id decides nothing.
    _callId = const Uuid().v4();
    _startedAt = DateTime.now();
    _localCandTypes.clear();
    _remoteCandTypes.clear();
    Diag.record(DiagArea.call, 'start', corr: _callId, fields: {
      'video': video,
      'relay_known': relayKnown,
      'chan': _chan != null,
      'chan_live': _chanLive,
    },);
    _setState(CallState.calling);
    // Before the camera even opens. An offer that cannot be signalled is not a
    // call: without this the app sent an offer and 37 candidates into a channel
    // the server had refused, then blamed the network 35 seconds later.
    if (!await _ensureChannel()) {
      // A resolution that landed inside the subscribe poll owns the controller
      // now; failing it here would end the call this device just adopted.
      if (attempt != _attempt) return;
      _failWithoutChannel('call_no_channel');
      return;
    }
    // The poll runs for up to five seconds and is the widest await before the
    // camera opens, so it is the likeliest place for a resolution to land. Past
    // this line the controller may already belong to the peer's call.
    if (attempt != _attempt) return;
    try {
      await _openMedia(video: video);
      if (attempt != _attempt) return;
      await _routeAudio();
      if (attempt != _attempt) return;
      // Before the peer connection exists, so the relay is in its ICE config
      // rather than arriving too late to be used.
      await _ensureRelay();
      if (attempt != _attempt) return;
      if (!relayAvailable) {
        // Deliberately NOT an abort any more. Aborting here bricked the first
        // call of every fresh install: relayAvailable is derived from
        // _cachedTurn, a new device has nothing on disk, and one cold-booting
        // edge-function fetch inside a 3s budget frequently does not land —
        // so the very first call a new user ever placed died instantly, with
        // no message, because lastError was read by nothing.
        //
        // A relay-less call is not a doomed call: many networks pair on host
        // or server-reflexive candidates, only ONE side needs a relay, and
        // credentials fetched after setLocalDescription still arrive in time
        // to be trickled. Proceed, and let the banner say the truth.
        debugPrint('[turn] placing call with no relay yet '
            '(${turnError ?? 'still fetching'}) — candidates may trickle in');
      }
      await _createPc();
      if (attempt != _attempt) return;
      final offer = await _pc!.createOffer();
      if (attempt != _attempt) return;
      await _pc!.setLocalDescription(offer);
      if (attempt != _attempt) return;
      _send('offer', {
        'sdp': offer.sdp,
        'type': offer.type,
        'video': video,
        // Says this device honours the tie-break. Build 9 puts call_id on every
        // signal but drops any offer that arrives while it is busy, so it can
        // only ever KEEP — and a tie-break against a peer that cannot yield is
        // a coin flip that loses half of all double-dials to a 35s timeout on
        // both phones. There is no update channel; mixed builds are the steady
        // state for a while.
        'glare': true,
      });
      final invite = _insertInvite(_callId!, offer.sdp ?? '', video);
      _inviteWrite = invite;
      unawaited(invite); // durable → FCM rings a closed app
      await CallForegroundService.start();
      // The service belongs to whichever call is live, so it is left running;
      // only the timer would be this dead attempt's, and arming it would end
      // the adopted call 35 seconds from now.
      if (attempt != _attempt) return;
      _startConnectTimeout();
    } catch (e) {
      if (attempt != _attempt) return;
      // e.g. camera/mic permission denied — don't hang on "Calling…".
      debugPrint('[call] startCall failed: $e');
      _lastError = _readableCallError(e);
      unawaited(_teardown(CallState.ended));
    }
  }

  /// A sentence the user can act on. The call screen pops itself the moment
  /// state returns to idle, so without this the whole failure is a flash.
  static String _readableCallError(Object e) {
    final s = e.toString();
    if (s.contains('NotAllowedError') || s.contains('Permission')) {
      return 'Miles needs camera and microphone access to call.';
    }
    if (s.contains('NotFoundError')) {
      return 'No camera or microphone found on this device.';
    }
    return 'Could not start the call. Please try again.';
  }

  // ── Incoming ──────────────────────────────────────────────────────────────
  RTCSessionDescription? _pendingOffer;
  bool _pendingVideo = true;

  /// Start ringing. The ONLY place that does, deliberately.
  ///
  /// isVideo used to be set at accept() and nowhere else, so while the phone
  /// was actually ringing it still held whatever the previous call left behind
  /// — _teardown resets it to true. An audio call therefore announced itself as
  /// an incoming VIDEO call and only became audio once answered, and after an
  /// audio call the next video call rang as audio. Two entry points, two
  /// chances to forget; now there is one.
  void _ring(
    RTCSessionDescription offer, {
    required bool video,
    required String from,
  }) {
    isCaller = false;
    _pendingOffer = offer;
    _pendingVideo = video;
    isVideo = video;
    peerName = from;
    _setState(CallState.ringing);
  }

  Future<void> accept() async {
    if (state != CallState.ringing || _pendingOffer == null) return;
    // Six awaits, and the same orphan shape as startCall: a hangup arriving
    // mid-accept runs _teardown, and without a generation the media and the
    // peer connection opened after it are published to a call that has ended.
    final attempt = ++_attempt;
    camOn = _pendingVideo;
    _startedAt = DateTime.now();
    _localCandTypes.clear();
    _remoteCandTypes.clear();
    Diag.record(DiagArea.call, 'accept', corr: _callId, fields: {
      'video': isVideo,
      'relay_known': relayKnown,
      'chan': _chan != null,
      'chan_live': _chanLive,
    },);
    // The answer and every candidate this side gathers ride the same channel.
    // Answering without it is a phone that rings, is picked up, and connects to
    // nothing — reported as "the call never worked", never as an error.
    if (!await _ensureChannel()) {
      if (attempt != _attempt) return;
      _failWithoutChannel('accept_no_channel');
      return;
    }
    if (attempt != _attempt) return;
    try {
      await _openMedia(video: isVideo);
      await _routeAudio();
      await _ensureRelay();
      await _createPc();
      await _pc!.setRemoteDescription(_pendingOffer!);
      _remoteSet = true;
      await _flushPending();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      // Everything below writes state a teardown has already reset.
      if (attempt != _attempt) return;
      _send('answer', {'sdp': answer.sdp, 'type': answer.type});
      // NOT connected — nothing has been negotiated with the network yet. Set
      // here, the callee showed "connected" over a black screen for 35s while
      // the caller still showed "Calling…", so the two people had two
      // irreconcilable stories and neither described the real failure.
      // onConnectionState is the only authority for connected.
      _setState(CallState.calling);
      // The callee had no timeout at all: its only exit was the caller's
      // hangup broadcast, and if that never arrived the wakelock and the
      // foreground service outlived a call that did not exist.
      _startConnectTimeout();
      _pendingOffer = null;
      await CallForegroundService.start();
    } catch (e) {
      if (attempt != _attempt) return;
      // `catch (_)` before: the exception was bound and dropped. It covers
      // _openMedia (permissions, camera in use by another app), _routeAudio,
      // _ensureRelay, _createPc and the SDP exchange — five very different
      // causes collapsed into one silent hangup, on the device that was TRYING
      // TO ANSWER. From the caller's side this is indistinguishable from being
      // ignored.
      Diag.record(DiagArea.call, 'accept_failed', corr: _callId, fields: {
        'error': e.runtimeType.toString(),
        'has_pc': _pc != null,
        'remote_set': _remoteSet,
      },);
      _send('hangup', {});
      unawaited(_teardown(CallState.ended));
    }
  }

  void decline() {
    _send('hangup', {});
    _teardown(CallState.ended);
  }

  void hangup() {
    _send('hangup', {});
    _teardown(CallState.ended);
  }

  // ── Media controls ──────────────────────────────────────────────────────────
  void toggleMic() {
    micOn = !micOn;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = micOn);
    notifyListeners();
  }

  void toggleCam() {
    camOn = !camOn;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = camOn);
    notifyListeners();
  }

  /// Send my whole display in place of my camera.
  ///
  /// This exists because two in-app browsers cannot share one login: each
  /// handset has its own cookie jar, so "we both watch the same video" is
  /// unreachable through the WebView. Capturing the display sidesteps it —
  /// whoever is signed in shares the pixels, and there is nothing to keep in
  /// sync because there is only one stream.
  Future<void> startScreenShare() async {
    if (state != CallState.connected || sharingScreen) {
      return;
    }
    // Two whole-display captures at once is a genuine feedback loop, not merely
    // a busy screen: each display contains a live picture of the other, so the
    // image nests inside itself until both encoders fall over. Nothing used to
    // stop it — this guard and the disabled button are the two halves of that.
    if (remoteScreen || remoteSharePending) {
      Diag.record(DiagArea.call, 'screen_share_refused', corr: _callId);
      return;
    }
    final attempt = _attempt;
    // Hold the cover down for the WHOLE start sequence.
    //
    // This is the single most consequential line in the file. Android's
    // MediaProjection consent dialog is a system Activity, and starting the
    // projection bounces us again — both drive the app through inactive and,
    // on most builds, paused. Without this flag main.dart raises the News
    // cover, which unmounts MaterialApp.router; the re-auth then rebuilds the
    // shell with a FRESH _AppShellState (_lastCallState back to idle) while
    // the GoRouter — a plain Provider, never invalidated — still has /call on
    // its stack. The very next notifyListeners() therefore read as a new
    // inactive -> active transition and pushed a SECOND call screen. Both
    // copies then drew the same two textureIds, and it happened again on every
    // later cover cycle, so the video stacked on itself once per trip out of
    // the app. Every other system-overlay call site in this app already sets
    // this; this one was the only one that did not.
    MilesApp.systemOverlayActive = true;
    final MediaStream screen;
    try {
      // Returns false when the consent dialog is cancelled; it does not throw.
      // It also drops the cached projection token on every call, which is what
      // Android 15+ demands — a spent token must never be replayed.
      //
      // No fullScreenOnly. Verified in the plugin source
      // (GetUserMediaImpl.java:207-215): true forces
      // createConfigForDefaultDisplay — whole display, always — while the
      // default intent gives Android 14's own picker, where "One app"
      // excludes the status bar, notifications, the launcher, the cover and
      // this app's PiP from every captured frame. The echo the owner
      // photographed was largely this one argument.
      if (!await Helper.requestCapturePermission()) return;
      if (attempt != _attempt) return;
      // Before the capture, not after: Android 14+ wants the mediaProjection
      // service already running when the virtual display is created.
      await CallForegroundService.addScreenShare();
      if (attempt != _attempt) return;

      try {
        // Every constraint is discarded on Android — GetUserMediaImpl's private
        // getDisplayMedia overload is never handed the constraints map at all,
        // and starts the capture at display.getRealSize() and a fixed 30fps. So
        // asking for a size here would be decoration; the size is dealt with on
        // the ENCODER instead, in [_applyScreenProfile].
        screen = await navigator.mediaDevices.getDisplayMedia({'video': true});
      } catch (_) {
        // A late failure arrives as a bare String from the plugin, not an
        // Exception. A share that will not start must not take the call with
        // it. The service type is put back so a call does not carry a
        // mediaProjection-typed foreground service for a projection that never
        // started.
        Diag.record(DiagArea.call, 'screen_share_failed', corr: _callId);
        await CallForegroundService.dropScreenShare();
        return;
      }
    } finally {
      MilesApp.systemOverlayActive = false;
    }
    final track = screen.getVideoTracks().firstOrNull;
    if (track == null || attempt != _attempt) {
      await _dropCapture(screen);
      await CallForegroundService.dropScreenShare();
      return;
    }
    _screenStream = screen;
    screenSelfRenderer.srcObject = screen;
    track.onEnded = () => unawaited(stopScreenShare());
    // The share gets its OWN peer connection, built fresh per share and torn
    // down with it. The call's connection is not renegotiated, retuned or even
    // touched — see [ScreenShareSession] for the architecture.
    // Same reason as the receive side: a share on a STUN-only connection is a
    // share that never connects between two carrier NATs.
    await _ensureRelay();
    final session = ScreenShareSession(
      send: _send,
      iceConfig: await _iceConfig(),
      onRemoteStream: (_) {},
      onEnded: () => unawaited(stopScreenShare()),
      stopHinted: () => _screenStopHinted,
    );
    // A teardown landing during the awaits above has already disposed the
    // capture and reset these; going on would announce a share on a call that
    // has ended, and _send would carry a null call_id the far side does not
    // drop — letterboxing their *next* call around an ordinary camera feed.
    if (attempt != _attempt) {
      await session.close();
      await _dropCapture(screen);
      await CallForegroundService.dropScreenShare();
      return;
    }
    // Close before overwrite. _receiveShare does this; this path did not, so
    // a live receive session here was orphaned — never closed, still holding
    // an ICE agent and sockets for the rest of the call.
    final displaced = _shareSession;
    _shareSession = session;
    if (displaced != null) await displaced.close();
    _pendingShareIce.clear();
    sharingScreen = true;
    _shareStartedAt = DateTime.now();
    _screenStopHinted = false;
    _send('screen', {'on': true});
    notifyListeners();
    // The faces are thumbnails for the length of the share, so the camera
    // stops paying full price: half resolution, half framerate. That is the
    // uplink and CPU the share's encoder climbs on — and it is what un-jams
    // the face tiles, which were starving against an uncapped 720p30 camera.
    await _setCameraShareProfile(damp: true);
    try {
      await session.startSharing(track, screen, _displayPixels());
    } catch (e) {
      // The capture is already running. Left alone it would keep recording the
      // display into a connection that never opened, with the system cast
      // indicator up and no button state to stop it.
      debugPrint('[call] share start failed: $e');
      Diag.record(DiagArea.call, 'screen_share_failed', corr: _callId);
      await stopScreenShare();
    }
  }

  Future<void> _dropCapture(MediaStream stream) async {
    try {
      await stream.dispose();
    } catch (_) {}
  }

  /// The capture is the real panel, in physical pixels — the same value
  /// `display.getRealSize()` hands the capturer on the native side.
  static Size _displayPixels() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return const Size(1080, 1920);
    return views.first.physicalSize;
  }

  bool _screenStopHinted = false;
  DateTime? _shareStartedAt;

  /// Events the vendored plugin forwards from MediaProjection's callback.
  void _onWebrtcPluginEvent(Map<String, dynamic> e) {
    if (e.containsKey('miles.screenCaptureStop')) {
      // NEVER a direct kill. Upstream's comment in the patched callback says
      // it out loud: on some OEMs onStop fires SPURIOUSLY right after capture
      // starts — the reason the body was empty. Build 59 trusted it verbatim
      // and every share on affected handsets died at birth. So: ignore the
      // documented just-started window entirely, and outside it treat the
      // event as a HINT that fast-tracks the stall watchdog — the share ends
      // on real evidence (frames actually stopped) within one stats sample
      // instead of three.
      final started = _shareStartedAt;
      final young = started != null &&
          DateTime.now().difference(started) < const Duration(seconds: 3);
      if (sharingScreen && !young) _screenStopHinted = true;
      return;
    }
    final resize = e['miles.screenCaptureContentResize'];
    if (resize is Map && sharingScreen) {
      final w = (resize['width'] as num?)?.toDouble();
      final h = (resize['height'] as num?)?.toDouble();
      if (w == null || h == null || w <= 0 || h <= 0) return;
      final display = _displayPixels();
      // Meaningfully smaller than the panel on either axis = the user picked
      // one app. Exact equality is wrong on purpose: insets and rounding make
      // a full-display capture a few pixels short on some OEMs.
      final scoped = w < display.width * 0.9 || h < display.height * 0.9;
      if (scoped != appScopedShare) {
        appScopedShare = scoped;
        notifyListeners();
      }
      // Re-aim the encoder at what is actually being captured: an app window
      // is smaller than the panel, and scaling from the panel's size would
      // shrink content that already fits the current rung's bound.
      final session = _shareSession;
      if (session != null) unawaited(session.retarget(Size(w, h)));
    }
  }

  /// Reshape the camera sender around a live share, both directions.
  ///
  /// ONLY scale and framerate, never bitrate: this plugin skips null
  /// parameter fields, so a bitrate cap set once could never be unset and
  /// would ride the camera forever after the share ends. Scale and framerate
  /// restore to the capture's own defaults (720p@30, `_openMedia`) — writing
  /// those pins values that were previously unset, which is harmless
  /// precisely because they equal the defaults; they must track `_openMedia`
  /// if its constraints ever change.
  Future<void> _setCameraShareProfile({required bool damp}) async {
    try {
      final pc = _pc;
      if (pc == null) return;
      for (final s in await pc.getSenders()) {
        if (s.track?.kind != 'video') continue;
        final params = s.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) return;
        for (final e in encodings) {
          e
            // Doubles and ints are load-bearing: the Android bridge
            // hard-casts scale to Double and framerate to Integer.
            ..scaleResolutionDownBy = damp ? 2.0 : 1.0
            ..maxFramerate = damp ? 15 : 30;
        }
        await s.setParameters(params);
        return;
      }
    } catch (e) {
      // Best effort in both directions — a camera at full price is a worse
      // share, not a broken call.
      debugPrint('[call] camera profile damp=$damp: $e');
    }
  }

  /// Take the display off the wire and drop the capture.
  ///
  /// Also the recovery path when the share was killed from Android's own cast
  /// notification: the plugin swallows that event, so the partner is left on a
  /// frozen last frame until this runs.
  Future<void> stopScreenShare() async {
    if (!sharingScreen) return;
    sharingScreen = false;
    // The share's whole connection goes with it — encoder, ladder state,
    // sockets. The call's connection was never involved and needs nothing
    // put back. The digest is taken BEFORE close(), which resets it.
    final session = _shareSession;
    _shareSession = null;
    final digest = session?.takeDigest();
    if (digest != null) {
      ErrorReporter.report(digest, StackTrace.current, kind: 'share-quality');
    }
    if (session != null) await session.close();
    await _setCameraShareProfile(damp: false);
    _send('screen', {'on': false});
    final screen = _screenStream;
    _screenStream = null;
    screenSelfRenderer.srcObject = null;
    appScopedShare = false;
    _screenStopHinted = false;
    _shareStartedAt = null;
    if (screen != null) await _dropCapture(screen);
    // The projection is gone; the service should stop claiming it.
    await CallForegroundService.dropScreenShare();
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    // The native callback reports whether the NEW camera is front-facing
    // (onCameraSwitchDone(boolean) -> result.success(b)), not whether the
    // switch succeeded. Treating it as a success flag left the preview
    // mirrored on the back camera — the exact bug it was meant to fix.
    frontCamera = await Helper.switchCamera(track);
    notifyListeners();
  }

  /// Route the call audio. Video calls belong on the speaker — the phone is
  /// held away from the face — and a voice call belongs at the ear.
  ///
  /// Called after the media is open, because the route is picked from the
  /// devices the audio manager can see at that moment.
  Future<void> _routeAudio() async {
    speakerOn = isVideo;
    try {
      if (isVideo) {
        // Prefer a headset if one is connected — a video call on the speaker
        // with earbuds in is not what anybody wants.
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        await Helper.setSpeakerphoneOn(false);
      }
    } catch (e) {
      debugPrint('[call] audio route failed: $e');
    }
    notifyListeners();
  }

  /// Speaker on/off. Turning it OFF re-scans and falls back to bluetooth, then
  /// a wired headset, then the earpiece — so this is the recovery path for a
  /// headset connected after the call started, which nothing else notices.
  Future<void> setSpeaker(bool on) async {
    speakerOn = on;
    notifyListeners();
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (e) {
      debugPrint('[call] speaker toggle failed: $e');
    }
  }

  /// Hide/show the call screen without ending the call (background pill).
  void setMinimized(bool v) {
    if (minimized == v) return;
    minimized = v;
    // Arm Android's PiP while the call is minimised, so pressing home carries
    // the call out of Miles instead of dropping it behind the disguise cover.
    // Disarmed when the call is expanded again — a full-screen call that
    // shrinks itself on every home press would be a surprise, not a feature.
    unawaited(PipMode.setWanted(v && state == CallState.connected));
    notifyListeners();
  }

  // ── Internals ───────────────────────────────────────────────────────────────
  Future<void> _openMedia({bool video = true}) async {
    final attempt = _attempt;
    final capture = navigator.mediaDevices.getUserMedia({
      // Left as a bare `true` deliberately, and it has to stay one: the plugin
      // only reads audio constraints nested under `mandatory`/`optional`, so a
      // flat map here would be parsed as empty and take the default echo
      // cancellation and noise suppression away with it. (It sets those two, not
      // auto gain — the settings map that claims otherwise is hardcoded.)
      'audio': true,
      // 1280x720x30 — the SAME values GetUserMediaImpl already falls back to
      // (DEFAULT_WIDTH/HEIGHT/FPS, :91-93), so this changes no behaviour; it
      // just states the capture rather than inheriting it.
      //
      // Flat ints, not an 'ideal' map: the plugin reads these with
      // getConstrainInt, which does not look inside an 'ideal' wrapper, so a
      // wrapped value would be silently ignored.
      //
      // No device tiering: capture resolution cannot be changed once the track
      // is open, so guessing a phone's class up front can only take away the
      // ability to do better. libwebrtc adapts downward per frame and recovers.
      'video': video
          ? {
              'facingMode': 'user',
              'width': 1280,
              'height': 720,
              'frameRate': 30,
            }
          : false,
    });
    _openingMedia = capture;
    MediaStream stream;
    try {
      stream = await capture;
    } finally {
      if (identical(_openingMedia, capture)) _openingMedia = null;
    }
    // The camera is physically opening here, so this is the widest await on a
    // call path and the one a glare resolution or a teardown lands inside.
    // Publishing over the live capture does not lose a reference, it strands
    // one: the displaced stream is still attached to the surviving call's peer
    // connection, and _teardown disposes the field, not the orphan — so the
    // microphone stays open past the call, the call screen and the next call.
    if (attempt != _attempt) {
      try {
        await stream.dispose();
      } catch (_) {}
      throw const _Superseded();
    }
    _localStream = stream;
    localRenderer.srcObject = stream;
    notifyListeners();
  }

  // Nothing is set on the encoder here, and the reason is NOT the one an
  // earlier version of this comment gave. Correcting it, because a wrong
  // comment here sends the next reader away from the only knob that matters.
  //
  // That version blamed degradationPreference = MAINTAIN_FRAMERATE for the
  // blur. Setting it was almost certainly a NO-OP: libwebrtc already uses
  // MAINTAIN_FRAMERATE by default for camera content. Which means this app is
  // trading resolution for framerate on every call right now, and removing the
  // line did not stop it. The honest suspect for that regression is the other
  // half of the change — promoting H264, which took every H264 entry from the
  // device's capabilities, profiles and packetization modes included, and let
  // whichever one libwebrtc listed first win.
  //
  // The one worth knowing before touching this again: forceSWCodecList defaults
  // to ["VP9"] (MethodCallHandlerImpl.java:417-419), so if VP9 wins negotiation
  // BOTH phones encode and decode it in software. The stats overlay reports the
  // negotiated codec; if it says vp9, that is the first thing to fix, and the
  // fix is to DEMOTE VP9 rather than to promote anything.
  //
  // Nothing changes here until a real call says which of cpu / bandwidth / none
  // is limiting it. That is what call_stats.dart is for.

  Future<void> _createPc() async {
    final attempt = _attempt;
    final config = await _iceConfig();
    final pc = await createPeerConnection(config);
    // _pc and the stats monitor are shared, and this method reaches them two
    // awaits in. A resolution or a teardown that landed in that gap has already
    // disposed what it owned; writing _pc here hands the live call a connection
    // it did not build and strands this one — ICE agent, sockets and TURN
    // allocation open, and an undisposed connection is what leaves
    // AudioSwitchManager unstopped for the next call.
    if (attempt != _attempt) {
      try {
        await pc.dispose();
      } catch (_) {}
      throw const _Superseded();
    }
    _pc = pc;
    // The ICE servers are read from the static cache HERE and setConfiguration
    // is called nowhere, so this count is final for this call: a relay that
    // lands afterwards cannot join it, whatever relayAvailable says later. When
    // this reads 0 and the banner said relay was fine, the fetch was simply too
    // slow for this attempt.
    Diag.record(DiagArea.call, 'pc_created', corr: _callId, fields: {
      'ice_servers': (config['iceServers'] as List?)?.length ?? 0,
      'relay_servers': _cachedTurn.where(_isRelay).length,
      'turn_error': turnError == null,
    },);
    // Start sampling NOW, not when the call connects. Started on Connected, the
    // monitor only ever ran on calls that succeeded — which are exactly the
    // calls that never needed a relay. The NO-RELAY banner was invisible in the
    // one situation it exists for.
    _statsMonitor.noRelay = !relayAvailable;
    _statsMonitor.start(pc);
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceGatheringState = (g) => Diag.record(
        DiagArea.call, 'ice_gathering',
        corr: _callId, fields: {'state': g.name},);
    pc.onIceConnectionState = (i) {
      // The transition sequence IS the diagnosis. checking→failed with no
      // remote candidates is signalling; checking→failed with both sides'
      // relays present is the network; connected→disconnected is a different
      // bug again. Only debugPrint saw any of it before.
      Diag.record(DiagArea.call, 'ice_connection', corr: _callId, fields: {
        'state': i.name,
        'local_relay': _localCandTypes['relay'] ?? 0,
        'remote_relay': _remoteCandTypes['relay'] ?? 0,
      },);
    };
    pc.onIceCandidate = (c) {
      // ' typ host|srflx|relay' — the only line that says whether TURN actually
      // allocated. Without a relay candidate here, two carrier NATs cannot pair.
      final t = _typeOf(c.candidate);
      _localCandTypes[t] = (_localCandTypes[t] ?? 0) + 1;
      Diag.record(DiagArea.call, 'ice_local_candidate',
          corr: _callId, fields: {'typ': t, 'n': _localCandTypes[t]},);
      _localCandidates
          .add(c); // keep so we can re-send if the callee was closed
      _send('ice', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      // The call's connection only ever carries the camera and the mic; the
      // display arrives on its own connection (see [ScreenShareSession]).
      if (event.streams.isEmpty) return;
      remoteRenderer.srcObject = event.streams.first;
      notifyListeners();
    };
    pc.onConnectionState = (s) {
      // Only the CURRENT connection may drive state. Tearing down disposes the
      // peer connection, which fires Closed on this very handler — so without
      // an identity check _teardown re-enters itself, and a connection that
      // died a moment ago can end the call that has already replaced it.
      if (!identical(pc, _pc)) return;
      Diag.record(DiagArea.call, 'pc_state', corr: _callId, fields: {
        'state': s.name,
        'ms_since_start': _startedAt == null
            ? null
            : DateTime.now().difference(_startedAt!).inMilliseconds,
      },);
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectTimer?.cancel();
        _setState(CallState.connected);
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _teardown(CallState.ended);
      }
    };
  }

  void _onSignal(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid) return; // ignore our own echo
    final kind = payload['kind']?.toString();
    // The pause is enforced in notify_call, which stops the PUSH — and the ring
    // does not only arrive by push. An offer also comes down this broadcast
    // channel, which is subscribed for the whole time the app is open, so a
    // server-side mute alone leaves a paused partner able to light up the
    // screen with a full-screen incoming call. That is the loudest channel in
    // the app; silencing the quiet one and not this one is not a pause.
    //
    // Dropped before the state machine sees it, so nothing adopts the call id
    // or leaves `ended` for it. To the caller it looks like a phone that did
    // not answer, which is exactly what the pause promises to look like.
    if (kind == 'offer' && ContactPause.isActive) {
      Diag.record(DiagArea.call, 'offer_dropped_paused',
          corr: payload['call_id']?.toString(),);
      return;
    }
    final data = payload['data'];
    final map =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final theirs = payload['call_id']?.toString();
    // `ended` is idle with a 300ms timer on it: _teardown has already reset
    // every field this device would ring with, and the settle timer re-checks
    // the state before firing, so this makes it a no-op rather than a race.
    // Without it, a partner redialling straight after a call that failed — the
    // follow-on of every glare that could not be resolved, and what people
    // actually do — got no ring at all and another 35s of "Calling…".
    if (kind == 'offer' && state == CallState.ended) _setState(CallState.idle);
    // Adopt the caller's id so both devices file this call under one name — but
    // only on an offer, and only from idle. `??=` never overwrote, and
    // _teardown never cleared it, so a controller that had held one call id
    // kept it for the life of the process and every later call filed its trace
    // under the FIRST call's id. Now that id also decides which signals this
    // device is willing to hear, so a stale one is no longer just a bad label.
    if (kind == 'offer' && state == CallState.idle) _callId = theirs ?? _callId;
    // Paired with signal_sent on the other device, this is what separates "the
    // offer was never sent" from "the offer was sent and never arrived". They
    // are indistinguishable from either phone alone, and they have different
    // causes.
    Diag.record(DiagArea.call, 'signal_received', corr: _callId ?? theirs,
        fields: {
      'kind': kind,
      'state': state.name,
      'foreign': theirs != null && _callId != null && theirs != _callId,
    },);
    // Everything except an offer belongs to a call this device is already in;
    // an offer necessarily carries an id we have never seen. Two calls exist on
    // this one channel during a glare, and a hangup for the loser's call would
    // otherwise tear down the winner's. The call being adopted is let through:
    // its hangup is how this device learns the winner gave up, and dropping it
    // left the yielder answering a call that no longer existed. Left permissive
    // until _callId is known: the FCM path learns its id from the invite row
    // and candidates that beat it there still have to reach _pendingRemote.
    if (kind != 'offer' &&
        theirs != null &&
        _callId != null &&
        theirs != _callId &&
        theirs != _resolvingCallId) {
      Diag.record(DiagArea.call, 'signal_foreign_call', corr: _callId, fields: {
        'kind': kind,
        'their_call': theirs,
      },);
      return;
    }
    switch (kind) {
      case 'offer':
        if (state != CallState.idle) {
          // Only an outgoing call that is still ours to give up can be yielded.
          // A teardown in flight reads `calling` with isCaller true for four
          // more awaits, and adopting into it hands the adoption a stream and a
          // peer connection that teardown is on its way to disposing.
          final canYield = isCaller &&
              state == CallState.calling &&
              !_tearingDown &&
              _resolvingCallId == null;
          // A peer that does not advertise the tie-break cannot yield: build 9
          // drops every offer that reaches it while busy, so it can only keep.
          // Tie-breaking against it decides half of all double-dials the wrong
          // way, and the wrong way is both phones on "Calling…" for 35s.
          final peerYields = map['glare'] as bool? ?? false;
          final glare = !canYield
              ? CallGlare.undecidable
              : peerYields
                  ? callGlareFor(mine: _callId, theirs: theirs)
                  : theirs == null
                      ? CallGlare.undecidable
                      : CallGlare.yieldToPeer;
          Diag.record(DiagArea.call, 'offer_glare', corr: _callId, fields: {
            'state': state.name,
            'is_caller': isCaller,
            'their_call': theirs,
            'peer_yields': peerYields,
            'outcome': glare.name,
          },);
          switch (glare) {
            case CallGlare.keepMine:
              // Nothing to send and nothing to tear down: their device computes
              // the mirror of this line and answers the offer already in flight.
              return;
            case CallGlare.yieldToPeer:
              _enterResolving(theirs!);
              unawaited(_adoptAndAnswer(
                RTCSessionDescription(
                    map['sdp']?.toString(), map['type']?.toString(),),
                video: map['video'] as bool? ?? true,
                id: theirs,
              ),);
              return;
            case CallGlare.undecidable:
              // Genuinely busy — ringing, connected, or mid-teardown. Today's
              // behaviour on purpose: a unilateral yield from here abandons a
              // call that is not the peer's to replace.
              Diag.record(DiagArea.call, 'offer_dropped_busy',
                  corr: _callId, fields: {'state': state.name},);
              return;
          }
        }
        _ring(
          RTCSessionDescription(
              map['sdp']?.toString(), map['type']?.toString(),),
          video: map['video'] as bool? ?? true,
          from: _ref.read(sessionProvider).partner?.displayName ?? 'Partner',
        );
      case 'answer':
        _applyAnswer(map);
      case 'ice':
        // Early, not stale: addressed to the id this device is in the middle of
        // adopting and does not answer to yet. Dropped, the adopted call starts
        // with no remote candidates at all — which reads in every trace as
        // signalling that never arrived.
        if (theirs != null && theirs == _resolvingCallId) {
          _resolvingIce.add(map);
          return;
        }
        _addIce(map);
      case 'share-offer':
        // The partner started a share: build the receive side of its
        // dedicated connection and answer.
        unawaited(_receiveShare(map));
      case 'share-answer':
        final session = _shareSession;
        if (session != null) unawaited(session.onAnswer(map));
      case 'share-ice':
        final session = _shareSession;
        if (session != null) {
          unawaited(session.onIce(map));
        } else if (_pendingShareIce.length < _maxPendingShareIce) {
          // Held, not dropped. Flushed the moment the session is published.
          _pendingShareIce.add(map);
        }
      case 'screen':
        final announced = map['on'] == true;
        remoteSharePending = announced;
        // Deliberately NOT `remoteScreen = announced`. The big view follows
        // frames, never an announcement — see [remoteSharePending].
        if (!announced) {
          remoteScreen = false;
          _pendingShareIce.clear();
          // While sharingScreen the held session is my SEND side — a stray
          // 'off' from the far side must not close it.
          if (!sharingScreen) {
            // Their share ended: drop the receive connection and the last
            // frame, or the next share would letterbox a stale picture.
            final session = _shareSession;
            _shareSession = null;
            if (session != null) unawaited(session.close());
            screenRenderer.srcObject = null;
          }
        }
        notifyListeners();
      case 'hangup':
        _teardown(CallState.ended);
    }
  }

  /// Build the receive side of the partner's share connection.
  ///
  /// Any session already held is superseded — either their previous share's
  /// receive side that a lost 'screen off' never closed, or a dead send side.
  Future<void> _receiveShare(Map<dynamic, dynamic> map) async {
    // Serialised against itself: this is called unawaited from the signal
    // switch, so two offers in flight ran two concurrent bodies and the second
    // closed the first's session while the first was still suspended inside
    // onOffer — which then operated on a disposed connection.
    final gate = _receiveGate.then((_) => _receiveShareLocked(map));
    _receiveGate = gate.catchError((_) {});
    return gate;
  }

  Future<void> _receiveShareLocked(Map<dynamic, dynamic> map) async {
    // Both pressed Share inside one round trip: the guards never saw each
    // other and both offers are on the wire.
    //
    // This was an unconditional "if (sharingScreen) stopScreenShare()", which
    // is SYMMETRIC — so both sides yielded, and simultaneous share killed both
    // shares every time, deterministically. The call already solved this exact
    // problem; reuse its tie-break so that exactly one side yields.
    if (sharingScreen) {
      // NOT callGlareFor. That compares two call ids, and it is right for the
      // call — where two DIFFERENT calls are competing. A share happens inside
      // one call, so both peers hold the SAME _callId, and callGlareFor returns
      // `undecidable` for equal ids. An earlier version of this used it anyway
      // and treated anything but keepMine as "yield", which is symmetric — so
      // both sides yielded and simultaneous share still killed both shares,
      // which is precisely the bug it was written to fix.
      //
      // isCaller is the asymmetry that already exists and is guaranteed
      // opposite on the two handsets: exactly one of them placed this call.
      if (shareGlareKeepsMine(isCaller: isCaller)) {
        // They will yield to me; ignore their offer and keep my share.
        _pendingShareIce.clear();
        Diag.record(DiagArea.call, 'share_glare_keep', corr: _callId);
        return;
      }
      Diag.record(DiagArea.call, 'share_glare_yield', corr: _callId);
      await stopScreenShare();
    }
    final old = _shareSession;
    _shareSession = null;
    if (old != null) await old.close();
    // The share gets its own connection, so it needs its own relay — and
    // _iceConfig() only reads whatever is already cached. On a cold or expired
    // cache that yielded a STUN-only share, which cannot connect at all
    // between two carrier NATs however healthy the call beside it looks.
    await _ensureRelay();
    final iceConfig = await _iceConfig();
    late final ScreenShareSession session;
    session = ScreenShareSession(
      send: _send,
      iceConfig: iceConfig,
      onRemoteStream: (stream) {
        if (!identical(session, _shareSession)) return;
        // ONLY here, on real pixels, does their display take the big view.
        screenRenderer.srcObject = stream;
        remoteScreen = true;
        notifyListeners();
      },
      // Their share failed, timed out, or never produced a frame.
      //
      // This was an empty callback, and that is why a failed negotiation left
      // the viewer holding a black full-screen letterbox with their partner's
      // face gone and nothing in existence able to bring it back.
      onEnded: () {
        if (!identical(session, _shareSession)) return;
        _shareSession = null;
        remoteScreen = false;
        remoteSharePending = false;
        screenRenderer.srcObject = null;
        notifyListeners();
        unawaited(session.close());
      },
      stopHinted: () => false,
    );
    // Published BEFORE the negotiation await, so share-ice arriving mid-offer
    // reaches the session's own pending queue instead of the floor.
    _shareSession = session;
    await session.onOffer(map);
    // Flushed AFTER the offer, and that ordering is the whole fix. onOffer is
    // what builds the peer connection, and onIce drops any candidate arriving
    // while `_pc` is still null — a guard that exists so a CLOSED session stops
    // accumulating them. Flushing first therefore fed every held candidate to
    // that guard: the buffer added to stop share-ice being dropped was itself
    // dropping all of it, and the receive side negotiated on host candidates
    // alone. Past this line `_remoteSet` is true and each one applies directly.
    if (_pendingShareIce.isNotEmpty) {
      final held = List<Map<dynamic, dynamic>>.from(_pendingShareIce);
      _pendingShareIce.clear();
      for (final c in held) {
        unawaited(session.onIce(c));
      }
    }
  }

  /// Open the window in which this device holds two calls at once.
  ///
  /// It closes the moment _callId becomes theirs, not when the answer goes out:
  /// from that line on their candidates carry an id this device recognises and
  /// take the ordinary path into _pendingRemote.
  void _enterResolving(String id) {
    _resolvingCallId = id;
    _resolvingIce.clear();
    Diag.record(DiagArea.call, 'glare_resolving', corr: _callId, fields: {
      'theirs': id,
    },);
  }

  /// Answer the peer's offer on a controller that is already mid-call.
  ///
  /// Both people pressed Call. Requiring the one that lost the tie-break to
  /// also press Accept is a bug, not a safeguard — so this never passes through
  /// ringing, and both sides read "Calling…" from the tap to the connection.
  Future<void> _adoptAndAnswer(
    RTCSessionDescription offer, {
    required bool video,
    required String id,
  }) async {
    // A capture already in flight is this process's one camera, and the offer
    // most often arrives inside it. Opening a second one hands Android a busy
    // camera, which fails the adoption and so ends BOTH calls; waiting is also
    // what lets keepMedia see the stream the displaced attempt was opening
    // instead of deciding there is none.
    final opening = _openingMedia;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {}
    }
    // An answer cannot add a video m-line the offer did not have. Keeping a
    // video capture for an audio offer leaves the camera on for a call that can
    // never show it, so the capture survives only when the kinds agree.
    final keepMedia = _localStream != null && video == isVideo;
    final attempt = await _discardOutgoingForResolution(keepMedia: keepMedia);
    // Those disposes are awaits. A hangup, a connect timeout or a Failed
    // connection landing in them runs _teardown, and reading the generation
    // after them made every later check blind to it — the adoption then built a
    // peer connection, a foreground service and a 35s timer under a controller
    // the UI had already returned to idle.
    if (attempt != _attempt) return;
    _callId = id;
    _resolvingCallId = null;
    isCaller = false;
    isVideo = video;
    camOn = video;
    _startedAt = DateTime.now();
    notifyListeners();
    Diag.record(DiagArea.call, 'glare_adopt', corr: id, fields: {
      'video': video,
      'kept_media': keepMedia,
      'queued_ice': _resolvingIce.length,
    },);
    try {
      if (!keepMedia) {
        await _openMedia(video: video);
        if (attempt != _attempt) return;
        await _routeAudio();
        if (attempt != _attempt) return;
      }
      // accept() awaits this and this path did not, which made the yielding
      // device the one place in the file that builds a peer connection on
      // whatever happened to be cached: iceServers are read once, at
      // construction, so a relay arriving afterwards cannot join the call. On a
      // cold cache that is a glare between two carrier NATs that cannot pair,
      // reported by pc_created as a TURN outage.
      await _ensureRelay();
      if (attempt != _attempt) return;
      await _createPc();
      if (attempt != _attempt) return;
      await _pc!.setRemoteDescription(offer);
      if (attempt != _attempt) return;
      _remoteSet = true;
      await _flushPending();
      for (final ice in _resolvingIce) {
        await _addIce(ice);
      }
      _resolvingIce.clear();
      final answer = await _pc!.createAnswer();
      if (attempt != _attempt) return;
      await _pc!.setLocalDescription(answer);
      if (attempt != _attempt) return;
      // The offer came in over this channel, so it was live a moment ago — but
      // a resume nulls it for the length of a removeChannel round trip, and
      // _send drops what it cannot put on the wire. The answer is the one
      // message whose loss nobody detects: the winner is waiting for it and has
      // no exit but its 35s timeout. Gated here, after the SDP is built, so it
      // cannot widen the window in which this device answers to two call ids.
      if (!await _ensureChannel()) {
        if (attempt != _attempt) return;
        _failWithoutChannel('glare_no_channel');
        return;
      }
      if (attempt != _attempt) return;
      _send('answer', {'sdp': answer.sdp, 'type': answer.type});
      _startConnectTimeout();
      await CallForegroundService.start();
    } catch (e) {
      if (attempt != _attempt) return;
      // The failure that is invisible from the other phone: it won the
      // tie-break, so it is sitting on "Calling…" waiting for an answer that
      // this device has already given up on producing.
      Diag.record(DiagArea.call, 'glare_adopt_failed', corr: _callId, fields: {
        'error': e.runtimeType.toString(),
        'has_pc': _pc != null,
        'remote_set': _remoteSet,
      },);
      _lastError = _readableCallError(e);
      _send('hangup', {});
      unawaited(_teardown(CallState.ended));
    }
  }

  /// Drop the outgoing call this device placed WITHOUT ending the call.
  ///
  /// Deliberately not _teardown. Teardown sets `ended`, nulls _pendingOffer,
  /// resets isVideo/camOn, stops the foreground service and lands on idle 300ms
  /// later — and the last of those is fatal here: the answer this device is
  /// about to build would be assembled by a controller on its way to idle, on a
  /// screen that pops itself the moment it arrives.
  ///
  /// Returns the generation it mints, because the disposes below are awaits and
  /// the caller must not read _attempt after them.
  Future<int> _discardOutgoingForResolution({required bool keepMedia}) async {
    // Synchronous, before the first await: the startCall still in flight must
    // be invalidated in this same turn of the event loop, or it resumes and
    // publishes its peer connection over the call being rescued.
    final attempt = ++_attempt;
    _connectTimer?.cancel();
    // The monitor's 2s timer would go on sampling the connection disposed
    // below, and `stats` would carry the abandoned call's last sample into the
    // adopted call's teardown row as if it described that one.
    _statsMonitor.stop();
    stats = null;
    // Nulled BEFORE dispose, not after. dispose() fires onConnectionState with
    // Closed synchronously, and that handler's `identical(pc, _pc)` guard is
    // still true until this line — so disposing first tears down the call this
    // method exists to save.
    final pc = _pc;
    _pc = null;
    // _pendingRemote is kept on purpose: the peer only ever built ONE
    // connection, so anything queued from it belongs to the survivor.
    _localCandidates.clear();
    _localCandTypes.clear();
    _remoteCandTypes.clear();
    _remoteSet = false;
    remoteRenderer.srcObject = null;
    screenRenderer.srcObject = null;
    final stream = keepMedia ? null : _localStream;
    if (!keepMedia) {
      _localStream = null;
      localRenderer.srcObject = null;
    }
    Diag.record(DiagArea.call, 'glare_discard', corr: _callId, fields: {
      'kept_media': keepMedia,
      'had_pc': pc != null,
      'queued_remote': _pendingRemote.length,
    },);
    // The row this attempt inserted is a durable ring, and nothing else in this
    // file deletes one. Chained behind the insert because that insert is
    // deliberately not awaited and would otherwise land after the delete.
    final orphan = _callId;
    final write = _inviteWrite;
    _inviteWrite = null;
    if (orphan != null) {
      unawaited(write == null
          ? _deleteInvite(orphan)
          : write.whenComplete(() => _deleteInvite(orphan)),);
    }
    try {
      await pc?.dispose();
    } catch (_) {}
    try {
      await stream?.dispose();
    } catch (_) {}
    return attempt;
  }

  Future<void> _applyAnswer(Map<String, dynamic> map) async {
    if (_pc == null) {
      Diag.record(DiagArea.call, 'answer_dropped_no_pc', corr: _callId);
      return;
    }
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(
          map['sdp']?.toString(), map['type']?.toString(),),);
    } catch (e) {
      // _onSignal is void and calls this without awaiting, so a throw here
      // became an unhandled async error the zone ate. The consequence is
      // specific and invisible: _remoteSet stays false, so EVERY remote
      // candidate queues in _pendingRemote forever and the call dies at 35s
      // looking exactly like candidates that never arrived.
      Diag.record(DiagArea.call, 'answer_failed', corr: _callId, fields: {
        'error': e.runtimeType.toString(),
      },);
      return;
    }
    _remoteSet = true;
    Diag.record(DiagArea.call, 'answer_applied',
        corr: _callId, fields: {'queued': _pendingRemote.length},);
    await _flushPending();
    // The callee just came online (it answered). If it was a CLOSED app it
    // missed our first ICE trickle — re-send everything we've gathered.
    for (final c in _localCandidates) {
      _send('ice', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    }
  }

  Future<void> _addIce(Map<String, dynamic> map) async {
    final c = RTCIceCandidate(
      map['candidate']?.toString(),
      map['sdpMid']?.toString(),
      (map['sdpMLineIndex'] as num?)?.toInt(),
    );
    // The candidate line itself is never recorded — it carries this device's
    // private and public addresses. The TYPE carries the entire diagnosis and
    // carries no address at all.
    final t = _typeOf(map['candidate']?.toString());
    _remoteCandTypes[t] = (_remoteCandTypes[t] ?? 0) + 1;
    Diag.record(DiagArea.call, 'ice_remote_candidate', corr: _callId, fields: {
      'typ': t,
      // Queued means it arrived before the remote description was set. A call
      // where every remote candidate queued and none flushed is a specific bug
      // with a specific fix, and it looks like a network failure.
      'queued': _pc == null || !_remoteSet,
    },);
    if (_pc == null || !_remoteSet) {
      _pendingRemote.add(c);
    } else {
      await _pc!.addCandidate(c);
    }
  }

  static String _typeOf(String? candidate) =>
      RegExp(r'typ (\w+)').firstMatch(candidate ?? '')?.group(1) ?? 'unknown';

  Future<void> _flushPending() async {
    for (final c in _pendingRemote) {
      await _pc?.addCandidate(c);
    }
    _pendingRemote.clear();
  }

  /// Put a signal on the wire.
  ///
  /// The kind goes under 'kind', NOT 'type'. realtime_client's send() mutates
  /// the payload map it is handed — `payload['type'] = type.toType()` at
  /// realtime_channel.dart:628 — so a key called 'type' is overwritten with the
  /// literal string 'broadcast' before it ever leaves the device. It also
  /// injects 'event'. Both names belong to the transport; using either for our
  /// own data silently destroys it.
  void _send(String kind, Map<String, dynamic> data) {
    final chan = _chan;
    if (chan == null) {
      // The `?.` made this the quietest failure in the call path: no channel,
      // no send, no error, no trace. It happens for real — a reconnect nulls
      // the channel for the length of a removeChannel round trip, and _init
      // returns early when the couple has not resolved yet.
      Diag.record(DiagArea.call, 'signal_dropped_no_channel',
          corr: _callId, fields: {'kind': kind},);
      return;
    }
    Diag.record(DiagArea.call, 'signal_sent', corr: _callId, fields: {
      'kind': kind,
      // Length, never the SDP: it carries both devices' IP addresses.
      if (data['sdp'] != null) 'sdp_len': (data['sdp'] as String?)?.length,
    },);
    chan.sendBroadcastMessage(
      event: 'signal',
      payload: {
        'from': _myUid,
        'kind': kind,
        // Carried on every signal so the callee adopts the caller's id and both
        // traces join, on the realtime path as well as the FCM one.
        'call_id': _callId,
        'data': data,
      },
    );
  }

  Future<void> _teardown(CallState end) async {
    // Re-entered for real: `await _pc?.dispose()` below fires this connection's
    // own onConnectionState(Closed), whose `identical(pc, _pc)` guard is still
    // true because _pc is nulled afterwards. The same flag is what tells the
    // glare branch that a controller still reading `calling` is on its way out.
    if (_tearingDown) return;
    _tearingDown = true;
    // Before anything can await: an attempt still in flight has to stop writing
    // to fields this method is about to reset, or it republishes _pc after the
    // dispose below and leaves the microphone open on a call that has ended.
    _attempt++;
    try {
      // The last stats sample is taken BEFORE the monitor stops, because it is
      // the only record of what the media path was actually doing at the end —
      // and it is discarded two lines below. On a call that connected and then
      // degraded, this row is the whole story.
      Diag.record(DiagArea.call, 'teardown', corr: _callId, fields: {
        'from_state': state.name,
        'connected_ever': stats != null,
        'ms': _startedAt == null
            ? null
            : DateTime.now().difference(_startedAt!).inMilliseconds,
        'relayed': stats?.relayed,
        'rtt_ms': stats?.rttMs,
        'rx_kbps': stats?.recvKbps,
        'tx_kbps': stats?.sendKbps,
      },);
      _connectTimer?.cancel();
      _statsMonitor.stop();
      stats = null;
      await CallForegroundService.stop();
      try {
        await _localStream?.dispose();
      } catch (_) {}
      try {
        // dispose(), not close(): the native close() clears the stream maps but
        // leaves the peerConnection field set, so AudioSwitchManager.stop()
        // never runs and the next call starts on a dirty audio session.
        // dispose() calls close() itself, so this is not skipping anything.
        await _pc?.dispose();
      } catch (_) {}
      _pc = null;
      _localStream = null;
      _pendingOffer = null;
      _pendingRemote.clear();
      _localCandidates.clear();
      _remoteSet = false;
      // Ten fields were reset here and not this one, and _onSignal assigned it
      // with `??=` — so the first call this controller ever saw named every
      // call after it. Signals are demuxed by call_id now, which turns that
      // stale id from a mislabelled trace into a device that answers to the
      // wrong call.
      _callId = null;
      _resolvingCallId = null;
      _resolvingIce.clear();
      _inviteWrite = null;
      isCaller = false;
      micOn = true;
      camOn = true;
      isVideo = true;
      speakerOn = true;
      frontCamera = true;
      // The field is raw-written like its neighbours, but the PiP disarm CANNOT
      // ride on setMinimized: its `minimized == v` early-out skips a field that
      // is already false, and Android's pipWanted is native state that outlives
      // this controller's idea of it. Left armed, the next home press — hours
      // later, no call in sight — floats the REAL Miles UI over the launcher,
      // and main.dart exempts PiP from the disguise cover, so nothing comes
      // down over it. Unconditional here, so no exit path can miss it.
      minimized = false;
      unawaited(PipMode.setWanted(false));
      sharingScreen = false;
      remoteScreen = false;
      remoteSharePending = false;
      _pendingShareIce.clear();
      // The projection is gone with the call. Without this the foreground
      // service keeps claiming mediaProjection for the rest of the process.
      unawaited(CallForegroundService.dropScreenShare());
      // Hangup mid-share is a common share end, so the digest is taken here
      // too (null on the receive side). No camera restore on purpose: the
      // peer connection is disposed below, and the next call builds fresh
      // senders at defaults.
      final shareSession = _shareSession;
      _shareSession = null;
      final shareDigest = shareSession?.takeDigest();
      if (shareDigest != null) {
        ErrorReporter.report(shareDigest, StackTrace.current,
            kind: 'share-quality',);
      }
      if (shareSession != null) await shareSession.close();
      try {
        await _screenStream?.dispose();
      } catch (_) {}
      _screenStream = null;
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      screenRenderer.srcObject = null;
      screenSelfRenderer.srcObject = null;
      appScopedShare = false;
      _screenStopHinted = false;
      _shareStartedAt = null;
      _setState(end);
      // settle back to idle so the next call can start
      Future.delayed(const Duration(milliseconds: 300), () {
        if (state == CallState.ended) _setState(CallState.idle);
      });
    } finally {
      _tearingDown = false;
    }
  }

  /// Keep the display awake while a call is up.
  ///
  /// Driven from the state machine rather than the screen, because the call
  /// survives the screen being minimised to the pill — and the phone going to
  /// sleep mid-sentence is a quality problem even though it is not a media one.
  Future<void> _setAwake(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('[call] wakelock failed: $e');
    }
  }

  void _setState(CallState s) {
    state = s;
    final live = s == CallState.calling ||
        s == CallState.ringing ||
        s == CallState.connected;
    // Static mirror for code with no Ref: the sound layer's call gate reads
    // this — PipMode alone missed the FULL-SCREEN call, so a chat cue could
    // play into the conversation's mic path.
    liveCall.value = live;
    unawaited(_setAwake(live));
    notifyListeners();
  }

  /// True whenever a call is being placed, ringing or connected.
  static final ValueNotifier<bool> liveCall = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _resubscribeTimer?.cancel();
    _connectTimer?.cancel();
    final ch = _chan;
    _chan = null;
    if (ch != null) SupabaseService.client.removeChannel(ch);
    _webrtcEventsSub?.cancel();
    _shareSession?.close();
    localRenderer.dispose();
    screenRenderer.dispose();
    remoteRenderer.dispose();
    screenSelfRenderer.dispose();
    _pc?.close();
    _localStream?.dispose();
    // Disposed here as well as in _teardown: a container torn down while a
    // share is live would otherwise leave MediaProjection recording the
    // display with nothing left in the app able to stop it.
    _screenStream?.dispose();
    super.dispose();
  }
}

/// Thrown by the attempt that no longer owns the controller, at the moment it
/// would have published a stream or a peer connection over the call that
/// replaced it. Every catch on a call path returns on the generation check
/// first, so this never reaches a user-facing message.
class _Superseded implements Exception {
  const _Superseded();
}

/// What a session change means for call signalling.
enum CallBinding { unchanged, bind, clear }

/// Pure, and deliberately outside the controller: the controller cannot be
/// constructed under test (RTCVideoRenderer needs the platform plugin) and this
/// decision is the part that was wrong.
CallBinding callBindingFor({
  required bool authenticated,
  required String? coupleId,
  required String? userId,
  required String? boundCoupleId,
  required String? boundUserId,
}) {
  // Signed out. Whoever signs in on this handset next must not inherit the
  // topic, the couple_id or the caller_id of the account that left.
  if (!authenticated) {
    return boundCoupleId == null && boundUserId == null
        ? CallBinding.unchanged
        : CallBinding.clear;
  }
  // The couple resolves late on a fresh account and goes null again on every
  // resume (see main.dart). A transient null is NOT a sign-out and must not
  // drop the channel a live call is signalling on.
  if (coupleId == null) return CallBinding.unchanged;
  // The user id matters on its own: both members of a couple share the couple
  // id, so a partner signing in on this phone changes only _myUid — which is
  // the caller_id every invite is written with, and the filter that decides
  // which broadcasts are our own echo.
  if (coupleId == boundCoupleId && userId == boundUserId) {
    return CallBinding.unchanged;
  }
  return CallBinding.bind;
}

/// What this device does with an offer that arrived while it was already
/// calling.
enum CallGlare { keepMine, yieldToPeer, undecidable }

/// Who keeps their outgoing call when both people dial inside the same window.
///
/// Both devices already hold both operands — _callId is minted locally and
/// rides every broadcast as payload['call_id'] — so this is decided twice,
/// independently, with no extra round trip, and the two answers have to be
/// mirror images. Lower id keeps its call, higher id yields.
///
/// Lowercased first, and that is the whole reason this is a function rather
/// than a `<`: 'A' is 0x41 and 'a' is 0x61, so an id that came back through a
/// payload in the other case would invert the comparison on ONE side. Both
/// devices then reach the same conclusion about themselves — both keep, or both
/// yield — and neither call is ever answered.
///
/// Deliberately not call_invites.created_at: the offer broadcast goes out
/// before that row is inserted, the row is sometimes never inserted at all, and
/// Postgres now() is transaction-start, so it ranks network latency rather than
/// who tapped. Deliberately not a time-ordered id (UUID v7 / ULID) either:
/// lexicographic order over one of those IS timestamp order, which puts the
/// decision back on two handset clocks that this repo has measured seconds
/// apart.
///
/// [CallGlare.undecidable] covers a missing id and two ids that compare equal.
/// Both fall through to the old drop-the-offer behaviour on purpose: a
/// unilateral yield against a peer that cannot reciprocate is the same no-call
/// outcome as the bug. A peer that does not advertise the tie-break at all is
/// handled before this is reached — it can only keep, so it is yielded to.
///
/// Pure and top-level for the same reason as [callBindingFor]: the controller
/// cannot be constructed under test, and this is the part that has to be right.
/// Who keeps their share when both people press Share at once.
///
/// Pure and top-level so it can actually be executed by a test — the thing the
/// broken version could not be, because it was buried in an async method on a
/// controller that cannot be constructed off-device.
///
/// The caller keeps. Any rule works as long as it is ASYMMETRIC: the failure it
/// replaces treated both peers identically, so both stopped and neither share
/// survived. [CallController.isCaller] is guaranteed opposite on the two
/// handsets — exactly one of them placed the call — and needs no extra
/// signalling, unlike a uid exchange.
bool shareGlareKeepsMine({required bool isCaller}) => isCaller;

CallGlare callGlareFor({required String? mine, required String? theirs}) {
  if (mine == null || mine.isEmpty || theirs == null || theirs.isEmpty) {
    return CallGlare.undecidable;
  }
  final a = mine.toLowerCase();
  final b = theirs.toLowerCase();
  if (a == b) return CallGlare.undecidable;
  return a.compareTo(b) < 0 ? CallGlare.keepMine : CallGlare.yieldToPeer;
}

final callControllerProvider = ChangeNotifierProvider<CallController>((ref) {
  final c = CallController(ref);
  c.init();
  // Not read once. The couple resolves asynchronously, so a read that wins that
  // race used to disable calling for the whole process, and a second account
  // signed in on the same handset used to keep the first one's couple.
  ref.listen<SessionState>(
    sessionProvider,
    (_, next) => c.bindSession(next),
    fireImmediately: true,
  );
  return c;
});
