import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:miles/features/call/call_stats.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/features/call/call_foreground.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      _chan = SupabaseService.client
          .channel('call:$id')
          .onBroadcast(event: 'signal', callback: _onSignal)
          .subscribe();
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
        _send('hangup', {});
        _teardown(CallState.ended);
      }
    });
  }

  /// Store the offer durably so a CLOSED callee can still answer; the insert
  /// trigger fires the FCM ring (call-notify).
  Future<void> _insertInvite(String offerSdp, bool video) async {
    final couple = _coupleId, me = _myUid;
    final callee = _ref.read(sessionProvider).partner?.id;
    if (couple == null || me == null || callee == null) return;
    try {
      await SupabaseService.client.from('call_invites').insert({
        'couple_id': couple,
        'caller_id': me,
        'callee_id': callee,
        'offer_sdp': offerSdp,
        'video': video,
      });
    } catch (_) {}
  }

  /// Ring a call delivered by FCM (the realtime offer was likely missed because
  /// the app was closed). Fetch the stored offer and present it as ringing.
  Future<void> handlePendingCall(
      String callId, String fromName, bool fallbackVideo) async {
    if (state != CallState.idle || callId.isEmpty) return;
    reconnect(); // make sure the call channel is live for the answer + ICE
    try {
      final row = await SupabaseService.client
          .from('call_invites')
          .select()
          .eq('id', callId)
          .maybeSingle();
      final sdp = row?['offer_sdp'] as String?;
      if (sdp == null || sdp.isEmpty || state != CallState.idle) return;
      _ring(
        RTCSessionDescription(sdp, 'offer'),
        video: (row?['video'] as bool?) ?? fallbackVideo,
        from: fromName,
      );
    } catch (_) {}
  }

  // ── ICE / TURN ─────────────────────────────────────────────────────────────
  static List<Map<String, dynamic>> _cachedTurn = [];
  static DateTime? _turnFetchedAt;

  /// Short-lived Cloudflare TURN ICE servers, minted by the `turn-credentials`
  /// edge function (the Cloudflare API token stays server-side, never in the
  /// app). Cached ~12h (the creds live 24h). Best-effort: on any failure we
  /// return whatever is cached (possibly nothing) and the call still connects on
  /// permissive networks via STUN.
  static Future<List<Map<String, dynamic>>> _turnServers() async {
    final at = _turnFetchedAt;
    if (at != null &&
        _cachedTurn.isNotEmpty &&
        DateTime.now().difference(at) < const Duration(hours: 12)) {
      return _cachedTurn;
    }
    try {
      final res = await SupabaseService.client.functions
          .invoke('turn-credentials')
          // 8s is not enough on a slow mobile network, and this runs while the
          // user is waiting to place a call.
          .timeout(const Duration(seconds: 15));

      final data = res.data;
      // The function reports its own failures as a JSON body with an 'error'
      // key and a non-200 status. Reading only 'iceServers' turned every one of
      // those — secrets missing, Cloudflare rejecting the token, the function
      // not deployed — into a silent empty list.
      if (data is Map && data['error'] != null) {
        turnError = 'server: ${data['error']}';
        debugPrint('[turn] edge function returned ${data['error']} '
            '(status ${res.status})');
        return _cachedTurn;
      }

      final raw = data is Map ? data['iceServers'] : null;
      if (raw is! List) {
        turnError = 'bad response shape';
        debugPrint('[turn] unexpected response: ${data.runtimeType} $data');
        return _cachedTurn;
      }

      final parsed = <Map<String, dynamic>>[];
      for (final srv in raw) {
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
        debugPrint('[turn] response carried ${parsed.length} servers but no '
            'turn:/turns: entry — relay is NOT available');
        return _cachedTurn;
      }

      _cachedTurn = parsed;
      _turnFetchedAt = DateTime.now();
      turnError = null;
      debugPrint('[turn] ok — $relays relay server(s)');
      return parsed;
    } on TimeoutException {
      turnError = 'timeout';
      debugPrint('[turn] credential fetch timed out');
    } catch (e) {
      turnError = '$e';
      debugPrint('[turn] credential fetch failed: $e');
    }
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

  /// Whether the last ICE config actually contained a relay.
  static bool relayAvailable = false;

  /// Full WebRTC ICE config: Google/Cloudflare STUN + Cloudflare TURN (which
  /// includes TURN-over-TLS:443 for carrier-NAT / UDP-blocked networks). A static
  /// TURN from .env (METERED_TURN_*) is appended if present, as a manual override.
  static Future<Map<String, dynamic>> _iceConfig() async {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ];
    servers.addAll(await _turnServers());

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
          'credential': cred
        },
      ]);
    }
    relayAvailable = servers.any(_isRelay);
    debugPrint('[turn] ice config: ${servers.length} servers, '
        'relay=${relayAvailable ? 'YES' : 'NO'}'
        '${turnError == null ? '' : ' (${turnError})'}');
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
    if (couple == null) return;
    _coupleId = couple.id;
    await _subscribeChannel();
    unawaited(
        _turnServers()); // pre-warm TURN creds so the first call is instant
  }

  // ── Outgoing ──────────────────────────────────────────────────────────────
  Future<void> startCall({bool video = true}) async {
    if (state != CallState.idle || _coupleId == null) return;
    isCaller = true;
    isVideo = video;
    camOn = video;
    minimized = false;
    peerName = _ref.read(sessionProvider).partner?.displayName ?? 'Partner';
    _setState(CallState.calling);
    try {
      await _openMedia(video: video);
      await _routeAudio();
      await _createPc();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send('offer', {'sdp': offer.sdp, 'type': offer.type, 'video': video});
      _insertInvite(offer.sdp ?? '', video); // durable → FCM rings a closed app
      await CallForegroundService.start(peerName ?? 'Partner');
      if (!relayAvailable) {
        // Without a relay this call can only connect if both people happen to
        // be on networks that allow a direct path — typically the same wifi.
        // Saying so beats 35 seconds of "Calling…" followed by nothing.
        debugPrint('[turn] WARNING: placing a call with NO relay available '
            '(${turnError ?? 'reason unknown'}). Cross-network calls will fail.');
      }
      _startConnectTimeout();
    } catch (_) {
      // e.g. camera/mic permission denied — don't hang on "Calling…".
      _teardown(CallState.ended);
    }
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
    try {
      await _openMedia(video: isVideo);
      await _routeAudio();
      await _createPc();
      await _pc!.setRemoteDescription(_pendingOffer!);
      _remoteSet = true;
      await _flushPending();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _send('answer', {'sdp': answer.sdp, 'type': answer.type});
      _setState(CallState.connected);
      _pendingOffer = null;
      await CallForegroundService.start(peerName ?? 'Partner');
    } catch (_) {
      _send('hangup', {});
      _teardown(CallState.ended);
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
    final pc = await createPeerConnection(await _iceConfig());
    _pc = pc;
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceCandidate = (c) {
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
      debugPrint('[call] pcstate ${s.name}');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectTimer?.cancel();
        _statsMonitor.noRelay = !relayAvailable;
        _statsMonitor.start(pc);
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
    switch (kind) {
      case 'offer':
        if (state != CallState.idle) return; // busy
        _ring(
          RTCSessionDescription(
              map['sdp']?.toString(), map['type']?.toString()),
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
    if (_pc == null) return;
    await _pc!.setRemoteDescription(
        RTCSessionDescription(map['sdp']?.toString(), map['type']?.toString()));
    _remoteSet = true;
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
    if (_pc == null || !_remoteSet) {
      _pendingRemote.add(c);
    } else {
      await _pc!.addCandidate(c);
    }
  }

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
    _chan?.sendBroadcastMessage(
      event: 'signal',
      payload: {'from': _myUid, 'kind': kind, 'data': data},
    );
  }

  Future<void> _teardown(CallState end) async {
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
