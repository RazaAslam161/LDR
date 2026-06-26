import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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
      isCaller = false;
      _pendingOffer = RTCSessionDescription(sdp, 'offer');
      _pendingVideo = (row?['video'] as bool?) ?? fallbackVideo;
      peerName = fromName;
      _setState(CallState.ringing);
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
      await _createPc();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
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

  Future<void> accept() async {
    if (state != CallState.ringing || _pendingOffer == null) return;
    isCaller = false;
    isVideo = _pendingVideo;
    camOn = _pendingVideo;
    try {
      await _openMedia(video: isVideo);
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
    if (track != null) await Helper.switchCamera(track);
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
      'audio': true,
      'video': video ? {'facingMode': 'user'} : false,
    });
    localRenderer.srcObject = _localStream;
    notifyListeners();
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
    final type = payload['type']?.toString();
    final data = payload['data'];
    final map =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    switch (type) {
      case 'offer':
        if (state != CallState.idle) return; // busy
        _pendingOffer = RTCSessionDescription(
            map['sdp']?.toString(), map['type']?.toString());
        _pendingVideo = map['video'] as bool? ?? true;
        peerName = _ref.read(sessionProvider).partner?.displayName ?? 'Partner';
        _setState(CallState.ringing);
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

  void _send(String type, Map<String, dynamic> data) {
    _chan?.sendBroadcastMessage(
      event: 'signal',
      payload: {'from': _myUid, 'type': type, 'data': data},
    );
  }

  Future<void> _teardown(CallState end) async {
    _connectTimer?.cancel();
    await CallForegroundService.stop();
    try {
      await _localStream?.dispose();
    } catch (_) {}
    try {
      await _pc?.close();
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
    minimized = false;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    _setState(end);
    // settle back to idle so the next call can start
    Future.delayed(const Duration(milliseconds: 300), () {
      if (state == CallState.ended) _setState(CallState.idle);
    });
  }

  void _setState(CallState s) {
    state = s;
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
