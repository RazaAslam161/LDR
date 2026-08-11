import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/features/call/call_foreground.dart';
import 'package:miles/features/call/call_stats.dart';
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

  RealtimeChannel? _chan;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
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

  /// (Re)subscribe `call:<coupleId>` cleanly — Pattern A: await removeChannel(old)
  /// before re-creating, so a reconnect never leaves a duplicate-topic channel
  /// joined-but-dead (which would silently drop incoming offer/answer/ice/hangup).
  Future<void> _subscribeChannel() async {
    final id = _coupleId;
    if (id == null || _subscribingChan) return;
    _subscribingChan = true;
    try {
      final old = _chan;
      _chan = null;
      if (old != null) {
        try {
          await SupabaseService.client.removeChannel(old);
        } catch (_) {}
      }
      // The status was thrown away here. Every signal this app sends goes over
      // this one channel, so a subscribe that lands in CHANNEL_ERROR or
      // TIMED_OUT means no offer, no answer, no ICE and no hangup ever moves —
      // and _send below drops them without a word. The call then fails at the
      // 35s timeout looking exactly like a network problem, which is where two
      // months of diagnosis went.
      _chan = SupabaseService.client
          .channel('call:$id', opts: RealtimeChannelConfig(private: true))
          .onBroadcast(event: 'signal', callback: _onSignal)
          .subscribe((status, err) {
        Diag.record(DiagArea.call, 'signal_subscribe', corr: _callId, fields: {
          'status': status.name,
          if (err != null) 'error': err.runtimeType.toString(),
        },);
      });
    } finally {
      _subscribingChan = false;
    }
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
        _send('hangup', {});
        _teardown(CallState.ended);
      }
    });
  }

  /// Store the offer durably so a CLOSED callee can still answer; the insert
  /// trigger fires the FCM ring (call-notify).
  Future<void> _insertInvite(String offerSdp, bool video) async {
    final couple = _coupleId;
    final me = _myUid;
    final callee = _ref.read(sessionProvider).partner?.id;
    if (couple == null || me == null || callee == null) {
      // Returned in silence. The FCM ring hangs entirely off this insert, so
      // this is "the callee's phone never made a sound" — and the caller's
      // screen is identical to a call that rang and went unanswered.
      Diag.record(DiagArea.call, 'invite_skipped', corr: _callId, fields: {
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
        'id': _callId,
        'couple_id': couple,
        'caller_id': me,
        'callee_id': callee,
        'offer_sdp': offerSdp,
        'video': video,
      });
      Diag.record(DiagArea.call, 'invite_inserted', corr: _callId);
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
      Diag.record(DiagArea.call, 'invite_failed', corr: _callId, fields: {
        'error': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
        'pg_msg': e is PostgrestException ? e.message : null,
      },);
    }
  }

  /// Ring a call delivered by FCM (the realtime offer was likely missed because
  /// the app was closed). Fetch the stored offer and present it as ringing.
  Future<void> handlePendingCall(
      String callId, String fromName, bool fallbackVideo,) async {
    if (state != CallState.idle || callId.isEmpty) return;
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
  /// waiting ~3s for; past that the offer goes out with whatever is known and
  /// relay candidates arrive by trickle, which is how ICE is designed to work.
  static Future<void> _ensureRelay({
    Duration budget = const Duration(seconds: 3),
  }) async {
    if (_cachedTurn.any(_isRelay)) return;
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
          'proceeding, candidates can still trickle in');
    } catch (e) {
      debugPrint('[turn] relay warm-up failed: $e');
    }
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

    final host = dotenv.maybeGet('METERED_TURN_HOST') ?? '';
    final user = dotenv.maybeGet('METERED_TURN_USERNAME') ?? '';
    final cred = dotenv.maybeGet('METERED_TURN_CREDENTIAL') ?? '';
    if (host.isNotEmpty && user.isNotEmpty && cred.isNotEmpty) {
      servers.addAll([
        {'urls': 'turn:$host:80', 'username': user, 'credential': cred},
        {'urls': 'turn:$host:443', 'username': user, 'credential': cred},
        {
          'urls': 'turns:$host:443?transport=tcp',
          'username': user,
          'credential': cred,
        },
      ]);
    }

    debugPrint('[turn] ice config: ${servers.length} servers, '
        'relay=${relayAvailable ? 'YES' : 'NO'}'
        '${turnError == null ? '' : ' ($turnError)'}');
    return {'iceServers': servers, 'sdpSemantics': 'unified-plan'};
  }

  bool _inited = false;

  /// Subscribe to the couple's call channel so incoming offers ring this device.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    final session = _ref.read(sessionProvider);
    final couple = session.couple;
    _myUid = session.profile?.id;
    // _inited is already true above, and _coupleId is assigned nowhere else in
    // this file — so returning here leaves this controller permanently unable to
    // subscribe or send, for the rest of the process, with no retry and nothing
    // logged. Whether that actually happens depends on whether the session had
    // resolved by the first read of callControllerProvider, which is a race.
    // This event is how a field test tells "calls never work on my phone" from
    // "calls failed this once".
    Diag.record(DiagArea.call, 'init', fields: {
      'has_couple': couple != null,
      'has_uid': _myUid != null,
    },);
    if (couple == null) return;
    _coupleId = couple.id;
    await _subscribeChannel();
    // Disk first so a call placed seconds after launch already has a relay,
    // then refresh in the background. Never awaited on a call path.
    await loadCachedTurn();
    warmRelay();
  }

  // ── Outgoing ──────────────────────────────────────────────────────────────
  Future<void> startCall({bool video = true}) async {
    if (state != CallState.idle || _coupleId == null) return;
    isCaller = true;
    isVideo = video;
    camOn = video;
    minimized = false;
    peerName = _ref.read(sessionProvider).partner?.displayName ?? 'Partner';
    // Minted here rather than by the database, because it has to be on the
    // broadcast offer AND be the invite row id — those are the two separate
    // paths a callee can learn about this call on, and both traces have to
    // land under one name.
    _callId = const Uuid().v4();
    _startedAt = DateTime.now();
    _localCandTypes.clear();
    _remoteCandTypes.clear();
    Diag.record(DiagArea.call, 'start', corr: _callId, fields: {
      'video': video,
      'relay_known': relayKnown,
      'chan': _chan != null,
    },);
    _setState(CallState.calling);
    try {
      await _openMedia(video: video);
      await _routeAudio();
      // Before the peer connection exists, so the relay is in its ICE config
      // rather than arriving too late to be used.
      await _ensureRelay();
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
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send('offer', {'sdp': offer.sdp, 'type': offer.type, 'video': video});
      unawaited(_insertInvite(offer.sdp ?? '', video)); // durable → FCM rings a closed app
      await CallForegroundService.start(peerName ?? 'Partner');
      _startConnectTimeout();
    } catch (e) {
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
    camOn = _pendingVideo;
    _startedAt = DateTime.now();
    _localCandTypes.clear();
    _remoteCandTypes.clear();
    Diag.record(DiagArea.call, 'accept', corr: _callId, fields: {
      'video': isVideo,
      'relay_known': relayKnown,
      'chan': _chan != null,
    },);
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
      await CallForegroundService.start(peerName ?? 'Partner');
    } catch (e) {
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
    notifyListeners();
  }

  // ── Internals ───────────────────────────────────────────────────────────────
  Future<void> _openMedia({bool video = true}) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      // Left as-is deliberately. The Android implementation already enables
      // echo cancellation, noise suppression and auto gain; spelling them out
      // as constraints risks a device rejecting the whole request.
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
    localRenderer.srcObject = _localStream;
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
    final config = await _iceConfig();
    final pc = await createPeerConnection(config);
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
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        notifyListeners();
      }
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
    final data = payload['data'];
    final map =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    // Adopt the caller's id so both devices file this call under one name. A
    // callee that already has one (woken by FCM) keeps it — they are the same
    // id, because the caller uses the invite row id for both.
    _callId ??= payload['call_id']?.toString();
    // Paired with signal_sent on the other device, this is what separates "the
    // offer was never sent" from "the offer was sent and never arrived". They
    // are indistinguishable from either phone alone, and they have different
    // causes.
    Diag.record(DiagArea.call, 'signal_received', corr: _callId, fields: {
      'kind': kind,
      'state': state.name,
    },);
    switch (kind) {
      case 'offer':
        if (state != CallState.idle) {
          // Dropped with no ring, no log, and nothing sent back to the caller,
          // who then waits out the full 35s. It matters because `state` can be
          // STUCK: any path that leaves it non-idle makes this device silently
          // unreachable while looking perfectly healthy.
          Diag.record(DiagArea.call, 'offer_dropped_busy',
              corr: _callId, fields: {'state': state.name},);
          return;
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
        _addIce(map);
      case 'hangup':
        _teardown(CallState.ended);
    }
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
      // leaves the peerConnection field set, so AudioSwitchManager.stop() never
      // runs and the next call starts on a dirty audio session. dispose() calls
      // close() itself, so this is not skipping anything.
      await _pc?.dispose();
    } catch (_) {}
    _pc = null;
    _localStream = null;
    _pendingOffer = null;
    _pendingRemote.clear();
    _localCandidates.clear();
    _remoteSet = false;
    isCaller = false;
    micOn = true;
    camOn = true;
    isVideo = true;
    speakerOn = true;
    frontCamera = true;
    minimized = false;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    _setState(end);
    // settle back to idle so the next call can start
    Future.delayed(const Duration(milliseconds: 300), () {
      if (state == CallState.ended) _setState(CallState.idle);
    });
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
    unawaited(_setAwake(live));
    notifyListeners();
  }

  @override
  void dispose() {
    final ch = _chan;
    _chan = null;
    if (ch != null) SupabaseService.client.removeChannel(ch);
    localRenderer.dispose();
    remoteRenderer.dispose();
    _pc?.close();
    _localStream?.dispose();
    super.dispose();
  }
}

final callControllerProvider = ChangeNotifierProvider<CallController>((ref) {
  final c = CallController(ref);
  c.init();
  return c;
});
