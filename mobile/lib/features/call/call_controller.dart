import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
          .timeout(const Duration(seconds: 8));
      final data = res.data;
      final raw = data is Map ? data['iceServers'] : null;
      if (raw is List) {
        final parsed = <Map<String, dynamic>>[];
        for (final s in raw) {
          if (s is! Map) continue;
          final m = Map<String, dynamic>.from(s);
          final urls = m['urls'];
          if (urls is List) {
            m['urls'] = urls.map((e) => e.toString()).toList();
          }
          parsed.add(m);
        }
        if (parsed.isNotEmpty) {
          _cachedTurn = parsed;
          _turnFetchedAt = DateTime.now();
          return parsed;
        }
      }
    } catch (_) {
      // best-effort — never block a call on the credential fetch
    }
    return _cachedTurn;
  }

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
      await _preferHardwareCodecs();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      await _applySendParameters();
      _send('offer', {'sdp': offer.sdp, 'type': offer.type, 'video': video});
      _insertInvite(offer.sdp ?? '', video); // durable → FCM rings a closed app
      await CallForegroundService.start(peerName ?? 'Partner');
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
      // After setRemoteDescription, not before: these are the transceivers that
      // actually produce the answer, and the only point where the intersection
      // with the caller's offer is known.
      await _preferHardwareCodecs();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _applySendParameters();
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
    if (await Helper.switchCamera(track)) {
      frontCamera = !frontCamera;
      notifyListeners();
    }
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
      // Flat ints, not an 'ideal' map: the plugin reads these with
      // getConstrainInt, which does not look inside an 'ideal' wrapper, so a
      // wrapped value is silently ignored and the capture falls back to a
      // default. 720p30 for everyone — no device tiering here, because capture
      // resolution CANNOT be changed once the track is open, while libwebrtc's
      // own overuse detector adapts downward per-frame and recovers. Guessing
      // a phone's class up front only takes away the ability to do better.
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

  /// Tell the encoder what to sacrifice when the network tightens.
  ///
  /// VIDEO SENDER ONLY, on purpose. RTCRtpParameters.fromMap turns a null
  /// degradationPreference into BALANCED rather than leaving it null, and
  /// toMap always emits it — so calling setParameters on the AUDIO sender to
  /// "leave it alone" would in fact write a degradation preference onto an
  /// audio track that never had one.
  ///
  /// No maxBitrate. Two people on wifi run a clean 720p30 at 2.5-3 Mbps today,
  /// and a ceiling is a permanent cost paid to solve a congestion problem that
  /// bandwidth estimation already solves — and that the encoder could recover
  /// from on its own once the network does.
  Future<void> _applySendParameters() async {
    final pc = _pc;
    if (pc == null || !isVideo) return;
    try {
      for (final sender in await pc.senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) continue;
        encodings.first.maxFramerate = 30;
        // Two people talking are mostly motion. A soft 480p at 30fps reads as
        // a live person; a sharp 720p at 12fps reads as a broken connection.
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_FRAMERATE;
        final ok = await sender.setParameters(params);
        debugPrint('[call] sender params applied=$ok');
      }
    } catch (e) {
      debugPrint('[call] sender params failed: $e');
    }
  }

  /// Ask for a hardware codec first.
  ///
  /// Every Android MediaCodec stack in practice has an AVC encoder; VP8
  /// hardware encode is not universal, and this plugin's encoder chain has no
  /// software fallback — a negotiated codec the device cannot encode means no
  /// video at all, on a call where audio works fine.
  ///
  /// A REORDER, never a filter: nothing is removed and nothing is added, only
  /// demoted, so if the peer somehow has nothing but VP9 the negotiation still
  /// succeeds. Built from this device's own capabilities.
  ///
  /// setCodecPreferences reports nothing back — the native side calls
  /// result.success(null) unconditionally — so the only evidence it worked is
  /// the m-line order of the SDP we go on to create. That is what the log line
  /// after createOffer/createAnswer is for.
  Future<void> _preferHardwareCodecs() async {
    final pc = _pc;
    if (pc == null || !isVideo) return;
    try {
      final caps = await getRtpSenderCapabilities('video');
      final codecs = caps.codecs;
      if (codecs == null || codecs.isEmpty) return;

      bool named(RTCRtpCodecCapability c, String name) =>
          c.mimeType.toLowerCase() == 'video/$name';

      final h264 = codecs.where((c) => named(c, 'h264')).toList();
      final vp8 = codecs.where((c) => named(c, 'vp8')).toList();
      if (h264.isEmpty && vp8.isEmpty) return; // nothing to promote
      final rest =
          codecs.where((c) => !named(c, 'h264') && !named(c, 'vp8')).toList();

      for (final t in await pc.getTransceivers()) {
        if (t.sender.track?.kind != 'video') continue;
        await t.setCodecPreferences([...h264, ...vp8, ...rest]);
      }
    } catch (e) {
      debugPrint('[call] codec preference failed: $e');
    }
  }

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
