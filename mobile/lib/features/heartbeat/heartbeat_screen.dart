import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/heartbeat/ppg_detector.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Feel My Heartbeat — your fingertip over the camera + torch reads your pulse;
/// your partner's phone throbs with your real heartbeat in real time, and vice
/// versa.
class HeartbeatScreen extends ConsumerStatefulWidget {
  const HeartbeatScreen({super.key});

  @override
  ConsumerState<HeartbeatScreen> createState() => _HeartbeatScreenState();
}

class _HeartbeatScreenState extends ConsumerState<HeartbeatScreen>
    with TickerProviderStateMixin {
  CameraController? _cam;
  bool _measuring = false;
  bool _busy = false;
  bool _processing = false;
  String? _error;

  RealtimeChannel? _channel;
  String? _coupleId;
  String? _myUid;
  late final PpgDetector _ppg;

  int? _myBpm;
  int? _partnerBpm;
  late final AnimationController _myPulse;
  late final AnimationController _partnerPulse;

  @override
  void initState() {
    super.initState();
    _myPulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _partnerPulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _ppg = PpgDetector(onBpm: _onMyBpm, onBeat: _onMyBeat);
    final session = ref.read(sessionProvider);
    _coupleId = session.couple?.id;
    _myUid = session.profile?.id;
    reportScreen(ref, 'Heartbeat');
    if (_coupleId != null) {
      _channel = SupabaseService.client
          .channel('heartbeat:${_coupleId!}')
          .onBroadcast(event: 'hb', callback: _onMsg)
          .subscribe();
    }
  }

  @override
  void dispose() {
    reportActiveTab(ref);
    _stopCamera();
    _channel?.unsubscribe();
    _myPulse.dispose();
    _partnerPulse.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final cam = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await cam.initialize();
      try {
        await cam.setFlashMode(FlashMode.torch);
      } catch (_) {/* some devices block torch in stream mode */}
      _ppg.reset();
      await cam.startImageStream(_onFrame);
      _cam = cam;
      if (mounted) {
        setState(() {
          _measuring = true;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not start the camera. Grant camera permission.';
        });
      }
    }
  }

  Future<void> _stopCamera() async {
    final cam = _cam;
    _cam = null;
    if (cam == null) return;
    try {
      await cam.setFlashMode(FlashMode.off);
    } catch (_) {}
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {}
    try {
      await cam.dispose();
    } catch (_) {}
  }

  Future<void> _stop() async {
    await _stopCamera();
    if (mounted) {
      setState(() {
        _measuring = false;
        _myBpm = null;
      });
    }
    _channel?.sendBroadcastMessage(
        event: 'hb', payload: {'from': _myUid, 'stopped': true});
  }

  void _onFrame(CameraImage image) {
    if (_processing) return;
    _processing = true;
    try {
      final bytes = image.planes[0].bytes; // luma plane
      var sum = 0;
      var count = 0;
      for (var i = 0; i < bytes.length; i += 16) {
        sum += bytes[i];
        count++;
      }
      if (count > 0) {
        _ppg.addSample(
            sum / count, DateTime.now().millisecondsSinceEpoch);
      }
    } catch (_) {
    } finally {
      _processing = false;
    }
  }

  void _onMyBpm(int bpm) {
    if (mounted) setState(() => _myBpm = bpm);
    _channel?.sendBroadcastMessage(
        event: 'hb', payload: {'from': _myUid, 'bpm': bpm});
  }

  void _onMyBeat() {
    if (mounted) _myPulse.forward(from: 0);
    _channel?.sendBroadcastMessage(
        event: 'hb', payload: {'from': _myUid, 'beat': true});
  }

  void _onMsg(Map<String, dynamic> payload) {
    if (!mounted || payload['from'] == _myUid) return;
    if (payload['stopped'] == true) {
      setState(() => _partnerBpm = null);
      return;
    }
    final bpm = payload['bpm'];
    if (bpm is num) setState(() => _partnerBpm = bpm.toInt());
    if (payload['beat'] == true) {
      _partnerPulse.forward(from: 0);
      HapticFeedback.lightImpact(); // feel their heartbeat
    }
  }

  @override
  Widget build(BuildContext context) {
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'Them';
    final myName = ref.watch(sessionProvider).profile?.displayName ?? 'You';
    return Scaffold(
      backgroundColor: MilesColors.night,
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Feel My Heartbeat'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _heart(
                label: partnerName,
                bpm: _partnerBpm,
                pulse: _partnerPulse,
                color: MilesColors.blush,
                hint: _partnerBpm == null
                    ? 'Ask $partnerName to start, and feel their heart here.'
                    : null,
              ),
            ),
            const Divider(height: 1, color: MilesColors.surface2),
            Expanded(
              child: _heart(
                label: '$myName (you)',
                bpm: _myBpm,
                pulse: _myPulse,
                color: MilesColors.ember,
                hint: _measuring
                    ? 'Cover the back camera + flash with your fingertip. Hold still…'
                    : null,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: MilesColors.ember, fontSize: 12)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : (_measuring ? _stop : _start),
                  child: Text(_busy
                      ? 'Starting…'
                      : (_measuring
                          ? 'Stop'
                          : 'Start — read my heartbeat')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heart({
    required String label,
    required int? bpm,
    required AnimationController pulse,
    required Color color,
    String? hint,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: pulse,
            builder: (context, _) {
              final scale = 1.0 + math.sin(pulse.value * math.pi) * 0.28;
              return Transform.scale(
                scale: scale,
                child: Icon(Icons.favorite, color: color, size: 92),
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            bpm != null ? '$bpm' : '—',
            style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 34,
                fontWeight: FontWeight.w700),
          ),
          Text('$label · BPM',
              style: const TextStyle(color: MilesColors.taupe, fontSize: 12)),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
              child: Text(hint,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: MilesColors.taupe, fontSize: 11.5)),
            ),
        ],
      ),
    );
  }
}
