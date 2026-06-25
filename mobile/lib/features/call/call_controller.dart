import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
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
  String? peerName; // who's calling / being called

  final List<RTCIceCandidate> _pendingRemote = [];
  bool _remoteSet = false;

  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'sdpSemantics': 'unified-plan',
  };

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
    _chan = SupabaseService.client
        .channel('call:${couple.id}')
        .onBroadcast(event: 'signal', callback: _onSignal)
        .subscribe();
  }

  // ── Outgoing ──────────────────────────────────────────────────────────────
  Future<void> startCall() async {
    if (state != CallState.idle || _coupleId == null) return;
    isCaller = true;
    peerName = _ref.read(sessionProvider).partner?.displayName ?? 'Partner';
    _setState(CallState.calling);
    try {
      await _openMedia();
      await _createPc();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send('offer', {'sdp': offer.sdp, 'type': offer.type});
    } catch (_) {
      // e.g. camera/mic permission denied — don't hang on "Calling…".
      _teardown(CallState.ended);
    }
  }

  // ── Incoming ──────────────────────────────────────────────────────────────
  RTCSessionDescription? _pendingOffer;

  Future<void> accept() async {
    if (state != CallState.ringing || _pendingOffer == null) return;
    isCaller = false;
    try {
      await _openMedia();
      await _createPc();
      await _pc!.setRemoteDescription(_pendingOffer!);
      _remoteSet = true;
      await _flushPending();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _send('answer', {'sdp': answer.sdp, 'type': answer.type});
      _setState(CallState.connected);
      _pendingOffer = null;
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

  // ── Internals ───────────────────────────────────────────────────────────────
  Future<void> _openMedia() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {'facingMode': 'user'},
    });
    localRenderer.srcObject = _localStream;
    notifyListeners();
  }

  Future<void> _createPc() async {
    final pc = await createPeerConnection(_rtcConfig);
    _pc = pc;
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceCandidate = (c) {
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
    _remoteSet = false;
    isCaller = false;
    micOn = true;
    camOn = true;
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
    _chan?.unsubscribe();
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
