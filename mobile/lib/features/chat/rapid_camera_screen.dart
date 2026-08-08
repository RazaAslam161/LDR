import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:miles/main.dart' show MilesApp;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/features/chat/camera_bake.dart';
import 'package:miles/features/chat/camera_filter_painter.dart';
import 'package:miles/features/chat/camera_filters.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

enum _CamState { preview, recording, captured, sending }

/// A fast, in-app camera with live filters baked into the photo on capture and a
/// one-tap send straight into the partner's chat.
///
/// Two modes:
/// - default (chat): "Send" uploads to couple_media + broadcasts the fast-path.
/// - [returnFile] (home check-in): "Use Photo" pops the baked file back to the
///   caller instead of sending to chat.
class RapidCameraScreen extends StatefulWidget {
  const RapidCameraScreen({
    super.key,
    required this.coupleId,
    required this.myUid,
    this.onSent,
    this.returnFile = false,
  });

  final String coupleId;
  final String myUid;
  final VoidCallback? onSent;
  final bool returnFile;

  @override
  State<RapidCameraScreen> createState() => _RapidCameraScreenState();
}

class _RapidCameraScreenState extends State<RapidCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  bool _ready = false;
  bool _denied = false;
  bool _flashOn =
      false; // Snapchat-style toggle: LED (back) / screen flash (front)
  bool _screenFlash = false; // white full-screen overlay during a front capture

  /// Opens on Original. A filter is a thing the user chooses, not something
  /// they have to notice and undo — and it is the only selection that lets a
  /// capture skip decode/re-encode entirely.
  CameraFilter _selectedFilter =
      kCameraFilters.firstWhere((f) => f.id == 'none');

  _CamState _state = _CamState.preview;
  File? _capturedFile;
  bool _annotating = false;

  // ── video recording (hold-to-record) ──
  bool _capturedIsVideo = false;
  VideoPlayerController? _videoPreview;
  Timer? _recordTimer;
  Duration _recordElapsed = Duration.zero;
  bool _recording = false; // guards start/stop re-entrancy
  bool _micGranted = false; // gates enableAudio so a denied mic can't fail init
  static const _maxRecord = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    if (mounted) setState(() => _denied = false);
    // Request camera permission EXPLICITLY up front. Relying on the camera
    // plugin's implicit request races the app-lifecycle (the OS dialog
    // backgrounds the app) and can leave initialize() hanging on a permanent
    // loading wheel. Doing it here means the controller is only ever created
    // once permission is already granted.
    // The OS camera/mic permission dialogs are system overlays — guard the
    // News cover so the first-run prompt can't drop us to the cover screen.
    MilesApp.systemOverlayActive = true;
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        debugPrint('[camera] permission not granted: $status');
        if (mounted) setState(() => _denied = true);
        return;
      }
      // Mic for hold-to-record video sound; non-fatal if denied (silent video).
      final mic = await Permission.microphone.request();
      _micGranted = mic.isGranted;
    } catch (e) {
      debugPrint('[camera] permission request failed: $e');
    } finally {
      MilesApp.systemOverlayActive = false;
    }
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        debugPrint('[camera] no cameras available');
        if (mounted) setState(() => _denied = true);
        return;
      }
      // Default to the FRONT camera (selfie — the common couple snap).
      _cameraIndex = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _initController(_cameras[_cameraIndex]);
    } catch (e) {
      debugPrint('[camera] boot failed: $e');
      if (mounted) setState(() => _denied = true);
    }
  }

  Future<void> _initController(CameraDescription camera) async {
    // veryHigh (~1080p, 2.07MP), not ultraHigh (2160p, 8.3MP).
    //
    // The plugin drives preview, capture AND the analysis stream off one
    // resolution, so 4K was being paid for four times over: the ISP encode, the
    // file write, the read back, the isolate copy, the decode, the re-encode
    // and the upload all scale with it. A chat photo is looked at in a 220dp
    // bubble. Dropping to 1080p is a 4x cut on every one of those at once, and
    // veryHigh is supported on far more hardware than ultraHigh.
    CameraController make(ResolutionPreset preset) => CameraController(
          camera,
          preset,
          // Only enable audio if mic was granted — enableAudio:true with a
          // denied mic can fail camera init on some devices.
          enableAudio: _micGranted,
        );

    // Ladder, not a cliff: an unsupported preset used to land the user on
    // "Camera unavailable" with no way back. Same shape as TouchMap's.
    var c = make(ResolutionPreset.veryHigh);
    _controller = c;
    try {
      // Hard timeout so a stalled platform init can never hang the UI forever.
      await c.initialize().timeout(const Duration(seconds: 12));
    } catch (e) {
      debugPrint('[camera] veryHigh failed ($e) — retrying at high');
      try {
        await c.dispose();
      } catch (_) {}
      c = make(ResolutionPreset.high);
      _controller = c;
      try {
        await c.initialize().timeout(const Duration(seconds: 12));
      } catch (e2) {
        debugPrint('[camera] init failed: $e2');
        if (mounted) setState(() => _denied = true);
        return;
      }
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    // Not awaited: the controller is already off, flash is applied at capture
    // time, and this was a platform round trip on the open path to reach a
    // state we are already in. Some devices reject it on the front camera.
    unawaited(c.setFlashMode(FlashMode.off).catchError((_) {}));
    // The preset is advisory — the plugin silently negotiates the closest
    // supported size and initialize() does not throw. Log what we actually got,
    // because it is the number every downstream cost scales with.
    debugPrint('[camera] preview=${c.value.previewSize}');
    setState(() => _ready = true);
  }

  void _retryBoot() {
    setState(() {
      _denied = false;
      _ready = false;
    });
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    // Release the camera only on a REAL background (paused/detached) and re-init
    // on return. NOT on `inactive` — that fires transiently when the camera
    // window first grabs focus on some OEMs, and disposing on it tore the
    // just-shown preview back down to a loading wheel.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _controller = null;
      c.dispose();
      // setState so the UI rebuilds to the loading state instead of trying to
      // paint a CameraPreview backed by a now-disposed controller.
      if (mounted) setState(() => _ready = false);
    } else if (state == AppLifecycleState.resumed && _cameras.isNotEmpty) {
      _initController(_cameras[_cameraIndex]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _restoreBrightness(); // never leave the screen stuck at max brightness
    _videoPreview?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  /// The active lens is the front (selfie) camera — drives mirroring of both the
  /// preview and the saved photo so a selfie reads the same way the user saw it.
  bool get _isFrontCamera =>
      _cameras.isNotEmpty &&
      _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

  // ── camera controls ───────────────────────────────────────────────────────
  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _ready = false);
    await _controller?.dispose();
    _controller = null;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initController(_cameras[_cameraIndex]); // filter is preserved
  }

  void _toggleFlash() => setState(() => _flashOn = !_flashOn);

  IconData get _flashIcon => _flashOn ? Icons.flash_on : Icons.flash_off;

  Future<void> _boostBrightness() async {
    try {
      await ScreenBrightness().setScreenBrightness(1.0);
    } catch (_) {}
  }

  Future<void> _restoreBrightness() async {
    try {
      await ScreenBrightness().resetScreenBrightness();
    } catch (_) {}
  }

  // ── capture + bake ────────────────────────────────────────────────────────
  Future<void> _capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) return;
    final mirror = _isFrontCamera; // capture now; flip can't change mid-bake
    // Snapchat-style flash: front has no LED → flash the screen white at full
    // brightness; back fires the real LED on capture.
    final screenFlash = _flashOn && _isFrontCamera;
    final ledFlash = _flashOn && !_isFrontCamera;
    try {
      final XFile xfile;
      if (screenFlash) {
        setState(() => _screenFlash = true);
        await _boostBrightness();
        // let the white screen actually light the face + exposure settle
        await Future.delayed(const Duration(milliseconds: 400));
        xfile = await c.takePicture();
        await _restoreBrightness();
        if (mounted) setState(() => _screenFlash = false);
      } else {
        if (ledFlash) {
          try {
            await c.setFlashMode(FlashMode.always);
          } catch (_) {}
        }
        xfile = await c.takePicture();
        // Not awaited — nothing downstream depends on the torch being off yet.
        if (ledFlash) unawaited(c.setFlashMode(FlashMode.off).catchError((_) {}));
      }
      if (!mounted) return;
      // PEAK QUALITY: an unfiltered, un-mirrored shot is sent EXACTLY as the
      // camera produced it — no decode/resize/re-encode, zero generation loss
      // (true device quality). Only filtered/mirrored shots are re-processed.
      if (_selectedFilter.id == 'none' && !mirror) {
        setState(() {
          _capturedFile = File(xfile.path);
          _capturedIsVideo = false;
          _state = _CamState.captured;
        });
        return;
      }
      setState(() => _state = _CamState.captured); // processing veil
      final bytes = await xfile.readAsBytes();
      final f = _selectedFilter;
      final out = await compute(
        bakeSnap,
        BakeRequest(
          bytes: bytes,
          filterId: f.id,
          matrix: f.colorMatrix,
          blurSigma: f.blurSigma,
          overlayArgb: f.overlayColor?.toARGB32(),
          overlayScreen: f.overlayBlendMode == BlendMode.screen,
          hasGrain: f.hasGrain,
          grainIntensity: f.grainIntensity,
          mirror: mirror,
        ),
      );
      final dir = await getTemporaryDirectory();
      final file =
          File('${dir.path}/snap_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(out);
      if (!mounted) return;
      setState(() {
        _capturedFile = file;
        _capturedIsVideo = false;
        _state = _CamState.captured;
      });
    } catch (_) {
      await _restoreBrightness();
      if (mounted) {
        setState(() {
          _screenFlash = false;
          _state = _CamState.preview;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not take that photo.')),
        );
      }
    }
  }

  // ── hold-to-record video ────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    final c = _controller;
    if (c == null ||
        !c.value.isInitialized ||
        _recording ||
        c.value.isRecordingVideo) {
      return;
    }
    _recording = true;
    try {
      await c.startVideoRecording();
      // Video flash: back → keep the LED torch on; front → boost screen
      // brightness for fill light (no white overlay so the preview stays visible).
      if (_flashOn) {
        if (_isFrontCamera) {
          await _boostBrightness();
        } else {
          try {
            await c.setFlashMode(FlashMode.torch);
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[camera] startVideoRecording failed: $e');
      _recording = false;
      return;
    }
    if (!mounted) return;
    _recordElapsed = Duration.zero;
    setState(() => _state = _CamState.recording);
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() => _recordElapsed += const Duration(milliseconds: 200));
      if (_recordElapsed >= _maxRecord)
        _stopRecording(); // auto-stop at the cap
    });
  }

  Future<void> _stopRecording() async {
    _recordTimer?.cancel();
    _recordTimer = null;
    final c = _controller;
    if (c == null || !_recording) return;
    _recording = false;
    // Clear any video flash (LED torch / boosted brightness).
    if (_flashOn) {
      await _restoreBrightness();
      try {
        await c.setFlashMode(FlashMode.off);
      } catch (_) {}
    }
    final elapsed = _recordElapsed;
    XFile xfile;
    try {
      xfile = await c.stopVideoRecording();
    } catch (e) {
      debugPrint('[camera] stopVideoRecording failed: $e');
      if (mounted) setState(() => _state = _CamState.preview);
      return;
    }
    // A too-short hold is an accidental tap-ish — discard, don't send a blip.
    if (elapsed < const Duration(milliseconds: 600)) {
      try {
        await File(xfile.path).delete();
      } catch (_) {}
      if (mounted) setState(() => _state = _CamState.preview);
      return;
    }
    final file = File(xfile.path);
    final vp = VideoPlayerController.file(file);
    try {
      await vp.initialize();
      await vp.setLooping(true);
      await vp.play();
    } catch (e) {
      debugPrint('[camera] video preview init failed: $e');
    }
    if (!mounted) {
      vp.dispose();
      return;
    }
    setState(() {
      _capturedFile = file;
      _capturedIsVideo = true;
      _videoPreview = vp;
      _state = _CamState.captured;
    });
  }

  Future<void> _retake() async {
    final f = _capturedFile;
    _capturedFile = null;
    _capturedIsVideo = false;
    final vp = _videoPreview;
    _videoPreview = null;
    vp?.dispose();
    setState(() => _state = _CamState.preview);
    try {
      await f?.delete();
    } catch (_) {}
  }

  // ── send ──────────────────────────────────────────────────────────────────
  Future<void> _send() async {
    final file = _capturedFile;
    if (file == null) return;

    // Home check-in accepts a photo only — pop it back to the caller. A video
    // always goes to chat (below).
    if (widget.returnFile && !_capturedIsVideo) {
      Navigator.pop(context, file);
      return;
    }

    setState(() => _state = _CamState.sending);
    try {
      if (_capturedIsVideo) {
        // Video → private couple_intimate bucket + kind:'video'. The partner's
        // chat renders it from the postgres echo (no image fast-path broadcast).
        await ChatRepository.sendVideo(widget.coupleId, file);
      } else {
        final sendId = const Uuid().v4();
        final path =
            await ChatRepository.sendImage(widget.coupleId, file, id: sendId);
        if (path != null) {
          // Fast-path: piggyback on the chat's live channel if it's open.
          ChatBroadcastService.broadcastImage(
            id: sendId,
            senderId: widget.myUid,
            imagePath: path,
          );
        }
      }
      widget.onSent?.call();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _CamState.captured);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Couldn't send — tap to retry"),
          action: SnackBarAction(label: 'Retry', onPressed: _send),
        ),
      );
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.night,
      body: _denied
          ? _CameraUnavailable(
              onRetry: _retryBoot,
              onClose: () => Navigator.pop(context),
            )
          : !_ready && _state == _CamState.preview
              ? const Center(
                  child: CircularProgressIndicator(color: MilesColors.ember))
              : (_state == _CamState.preview || _state == _CamState.recording)
                  ? _buildPreview()
                  : _buildCaptured(),
    );
  }

  // ── preview state ─────────────────────────────────────────────────────────
  Widget _buildPreview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: MilesColors.ember));
    }
    // 1. live filtered viewfinder. The preview is NOT mirrored (shows the true
    //    camera orientation) — the mirror is applied only to the SAVED photo
    //    (bakeSnap flipHorizontal), per the requested behaviour.
    final viewfinder = FilterPreviewLayer(
      filter: _selectedFilter,
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: c.value.previewSize?.height ?? 1080,
            height: c.value.previewSize?.width ?? 1920,
            child: CameraPreview(c),
          ),
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        viewfinder,

        // 2. top bar (hidden while recording)
        if (_state != _CamState.recording)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundIcon(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
                  Row(
                    children: [
                      _RoundIcon(icon: _flashIcon, onTap: _toggleFlash),
                      const SizedBox(width: 8),
                      _RoundIcon(
                        icon: Icons.flip_camera_android,
                        onTap: _flipCamera,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

        // REC pill while recording
        if (_state == _CamState.recording)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _RecPill(elapsed: _recordElapsed),
              ),
            ),
          ),

        // 3. + 4. filter name label + bottom glass panel
        Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_state != _CamState.recording)
                _FilterNameLabel(filter: _selectedFilter),
              const SizedBox(height: 10),
              _bottomPanel(),
            ],
          ),
        ),

        // Snapchat-style front screen-flash: a full white sheet at max
        // brightness that lights the face for the moment of capture.
        if (_screenFlash)
          const Positioned.fill(child: ColoredBox(color: Colors.white)),
      ],
    );
  }

  Widget _bottomPanel() {
    final recording = _state == _CamState.recording;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          color: MilesColors.surfaceGlass,
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 72,
                  child: recording
                      ? const Center(
                          child: Text(
                            'Recording… release to stop',
                            style: TextStyle(
                                color: MilesColors.cream100, fontSize: 12),
                          ),
                        )
                      : _filterStrip(),
                ),
                const SizedBox(height: 14),
                _CaptureButton(
                  recording: recording,
                  onTap: _capture,
                  onLongPressStart: _startRecording,
                  onLongPressEnd: _stopRecording,
                ),
                if (!recording)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Tap for photo · hold for video',
                      style: TextStyle(color: MilesColors.taupe, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterStrip() {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      physics: const BouncingScrollPhysics(),
      itemCount: kCameraFilters.length,
      itemBuilder: (context, i) {
        final f = kCameraFilters[i];
        final selected = f.id == _selectedFilter.id;
        return _FilterChip(
          filter: f,
          selected: selected,
          onTap: () => setState(() => _selectedFilter = f),
        );
      },
    );
  }

  // ── captured state ────────────────────────────────────────────────────────
  Widget _buildCaptured() {
    final file = _capturedFile;
    if (file == null) {
      // Capture in flight — brief processing veil (no jank; bake runs off-isolate).
      return Container(
        color: MilesColors.nightDeep,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: MilesColors.ember),
      );
    }

    if (_capturedIsVideo) {
      return _VideoReview(
        controller: _videoPreview,
        sending: _state == _CamState.sending,
        sendLabel: 'Send 💌',
        onRetake: _retake,
        onSend: _send,
      );
    }

    return _AnnotateHost(
      key: ValueKey(file.path),
      imageFile: file,
      annotating: _annotating,
      onAnnotateStart: () => setState(() => _annotating = true),
      onAnnotateDone: (newFile) {
        setState(() {
          _annotating = false;
          if (newFile != null) _capturedFile = newFile;
        });
      },
      onAnnotateCancel: () => setState(() => _annotating = false),
      onRetake: _retake,
      onSend: _send,
      sending: _state == _CamState.sending,
      sendLabel: widget.returnFile ? 'Use Photo' : 'Send 💌',
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Small UI pieces
// ════════════════════════════════════════════════════════════════════════════

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.onRetry, required this.onClose});
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _RoundIcon(icon: Icons.arrow_back, onTap: onClose),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: GlassPanel(
              glow: MilesColors.ember,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.no_photography_outlined,
                      color: MilesColors.emberSoft, size: 40),
                  const SizedBox(height: 14),
                  Text('Camera unavailable',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  const Text(
                    'Allow camera access to send a quick snap.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: MilesColors.taupe),
                  ),
                  const SizedBox(height: 18),
                  GlowButton(
                    label: 'Try again',
                    expand: false,
                    onPressed: onRetry,
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: MilesColors.cream50, size: 24),
        ),
      ),
    );
  }
}

class _FilterNameLabel extends StatelessWidget {
  const _FilterNameLabel({required this.filter});
  final CameraFilter filter;

  @override
  Widget build(BuildContext context) {
    return Animate(
      key: ValueKey(filter.id), // re-runs the fade on every filter change
      effects: const [
        FadeEffect(begin: 0, end: 1, duration: Duration(milliseconds: 250)),
        FadeEffect(
          begin: 1,
          end: 0,
          delay: Duration(milliseconds: 950),
          duration: Duration(milliseconds: 250),
        ),
      ],
      child: Text(
        '${filter.icon}  ${filter.label}',
        style: const TextStyle(
          fontFamily: 'Fraunces',
          color: MilesColors.cream50,
          fontSize: 18,
          shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.selected,
    required this.onTap,
  });

  final CameraFilter filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: selected ? 1.08 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 62,
          margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? MilesColors.ember : Colors.transparent,
              width: 3,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(filter.icon, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 2),
              Text(
                filter.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  color: MilesColors.cream100,
                  fontSize: 8,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    this.recording = false,
  });
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: (_) => onLongPressStart(),
      onLongPressEnd: (_) => onLongPressEnd(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: recording ? 84 : 72,
        height: recording ? 84 : 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: recording ? null : MilesGradients.cta,
          color: recording ? MilesColors.blush : null,
          boxShadow: [
            BoxShadow(
              color: recording ? MilesColors.blush : MilesColors.ember,
              blurRadius: 16,
            ),
          ],
        ),
        child: Center(
          child: recording
              ? Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: MilesColors.cream50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                )
              : Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: MilesColors.cream50, width: 3),
                  ),
                ),
        ),
      ),
    );
  }
}

class _RecPill extends StatelessWidget {
  const _RecPill({required this.elapsed});
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final s = elapsed.inSeconds;
    final mm = (s ~/ 60).toString();
    final ss = (s % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
                color: MilesColors.blush, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text('$mm:$ss',
              style: const TextStyle(
                  color: MilesColors.cream50, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Review a just-recorded video (looping playback) with Retake / Send.
class _VideoReview extends StatelessWidget {
  const _VideoReview({
    required this.controller,
    required this.sending,
    required this.sendLabel,
    required this.onRetake,
    required this.onSend,
  });
  final VideoPlayerController? controller;
  final bool sending;
  final String sendLabel;
  final VoidCallback onRetake;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (c != null && c.value.isInitialized)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          )
        else
          const Center(
              child: CircularProgressIndicator(color: MilesColors.ember)),
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _RoundIcon(icon: Icons.arrow_back, onTap: onRetake),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: _GlassBar(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: onRetake,
                  child: const Text('Retake',
                      style: TextStyle(color: MilesColors.cream100)),
                ),
                SizedBox(
                  width: 130,
                  child: GlowButton(
                    label: sendLabel,
                    loading: sending,
                    onPressed: sending ? null : onSend,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (sending)
          Container(
            color: MilesColors.ember.withValues(alpha: 0.3),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: MilesColors.cream50),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Captured-photo host: review, annotate (draw + emoji stamps), send/use.
// ════════════════════════════════════════════════════════════════════════════

class _Stroke {
  _Stroke(this.color);
  final Color color;
  final List<Offset> points = [];
}

class _Sticker {
  _Sticker(this.emoji, this.pos);
  final String emoji;
  Offset pos;
}

class _AnnotateHost extends StatefulWidget {
  const _AnnotateHost({
    super.key,
    required this.imageFile,
    required this.annotating,
    required this.onAnnotateStart,
    required this.onAnnotateDone,
    required this.onAnnotateCancel,
    required this.onRetake,
    required this.onSend,
    required this.sending,
    required this.sendLabel,
  });

  final File imageFile;
  final bool annotating;
  final VoidCallback onAnnotateStart;
  final ValueChanged<File?> onAnnotateDone;
  final VoidCallback onAnnotateCancel;
  final VoidCallback onRetake;
  final VoidCallback onSend;
  final bool sending;
  final String sendLabel;

  @override
  State<_AnnotateHost> createState() => _AnnotateHostState();
}

class _AnnotateHostState extends State<_AnnotateHost> {
  static const _emojis = [
    '💕', '💞', '💗', '💋', '🫂', '✨', //
    '🌙', '🔥', '💌', '😈', '🥺', '🤍',
  ];

  final _captureKey = GlobalKey();
  final List<_Stroke> _strokes = [];
  final List<_Sticker> _stickers = [];
  Color _penColor = MilesColors.blush;

  void _clearAnnotations() {
    _strokes.clear();
    _stickers.clear();
  }

  Future<void> _flattenAndDone() async {
    try {
      final boundary = _captureKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final ui.Image image = await boundary.toImage(pixelRatio: dpr);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        widget.onAnnotateDone(null);
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/annot_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      _clearAnnotations();
      widget.onAnnotateDone(file);
    } catch (_) {
      widget.onAnnotateDone(null);
    }
  }

  void _cancelAnnotate() {
    setState(_clearAnnotations);
    widget.onAnnotateCancel();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The flatten target — image + committed annotations.
        RepaintBoundary(
          key: _captureKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(widget.imageFile, fit: BoxFit.cover),
              // strokes
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _StrokePainter(_strokes)),
                ),
              ),
              // emoji stickers
              for (final s in _stickers)
                Positioned(
                  left: s.pos.dx,
                  top: s.pos.dy,
                  child: GestureDetector(
                    onPanUpdate: widget.annotating
                        ? (d) => setState(() => s.pos += d.delta)
                        : null,
                    onLongPress: widget.annotating
                        ? () => setState(() => _stickers.remove(s))
                        : null,
                    child: Text(s.emoji, style: const TextStyle(fontSize: 44)),
                  ),
                ),
            ],
          ),
        ),

        // Drawing surface (only while annotating).
        if (widget.annotating)
          Positioned.fill(
            child: GestureDetector(
              onPanStart: (d) => setState(() {
                final stroke = _Stroke(_penColor)..points.add(d.localPosition);
                _strokes.add(stroke);
              }),
              onPanUpdate: (d) => setState(() {
                if (_strokes.isNotEmpty)
                  _strokes.last.points.add(d.localPosition);
              }),
              behavior: HitTestBehavior.translucent,
            ),
          ),

        // Top retake arrow (review mode only).
        if (!widget.annotating)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(
                alignment: Alignment.topLeft,
                child:
                    _RoundIcon(icon: Icons.arrow_back, onTap: widget.onRetake),
              ),
            ),
          ),

        // Bottom controls.
        Align(
          alignment: Alignment.bottomCenter,
          child: widget.annotating ? _annotateBar() : _reviewBar(),
        ),

        if (widget.sending)
          Container(
            color: MilesColors.ember.withValues(alpha: 0.3),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: MilesColors.cream50),
          ),
      ],
    );
  }

  Widget _reviewBar() {
    return _GlassBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: widget.onRetake,
            child: const Text('Retake',
                style: TextStyle(color: MilesColors.cream100)),
          ),
          _RoundIcon(icon: Icons.edit, onTap: widget.onAnnotateStart),
          SizedBox(
            width: 130,
            child: GlowButton(
              label: widget.sendLabel,
              loading: widget.sending,
              onPressed: widget.sending ? null : widget.onSend,
            ),
          ),
        ],
      ),
    );
  }

  Widget _annotateBar() {
    return _GlassBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // emoji stamps
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final e in _emojis)
                  GestureDetector(
                    onTap: () => setState(() =>
                        _stickers.add(_Sticker(e, const Offset(150, 280)))),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: _cancelAnnotate,
                child: const Text('Cancel',
                    style: TextStyle(color: MilesColors.cream100)),
              ),
              // pen colour toggle
              Row(
                children: [
                  _PenDot(
                    color: MilesColors.blush,
                    selected: _penColor == MilesColors.blush,
                    onTap: () => setState(() => _penColor = MilesColors.blush),
                  ),
                  const SizedBox(width: 10),
                  _PenDot(
                    color: MilesColors.ember,
                    selected: _penColor == MilesColors.ember,
                    onTap: () => setState(() => _penColor = MilesColors.ember),
                  ),
                ],
              ),
              TextButton(
                onPressed: _flattenAndDone,
                child: const Text('Done',
                    style: TextStyle(
                        color: MilesColors.emberSoft,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlassBar extends StatelessWidget {
  const _GlassBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          color: MilesColors.surfaceGlass,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: SafeArea(top: false, child: child),
        ),
      ),
    );
  }
}

class _PenDot extends StatelessWidget {
  const _PenDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? MilesColors.cream50 : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes);
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final pts = stroke.points;
      if (pts.length == 1) {
        canvas.drawPoints(ui.PointMode.points, pts, paint);
        continue;
      }
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_StrokePainter oldDelegate) => true;
}
