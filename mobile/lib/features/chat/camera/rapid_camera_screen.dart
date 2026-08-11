import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/chat/camera/camera_bake.dart';
import 'package:miles/features/chat/camera/camera_filter_painter.dart';
import 'package:miles/features/chat/camera/camera_filters.dart';
import 'package:miles/features/chat/camera/zoom_controller.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:miles/main.dart' show MilesApp;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
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
    required this.coupleId, required this.myUid, super.key,
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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
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

  /// Zoom. The bounds come from the device, not from a guess — a phone with no
  /// telephoto reports max == min and the gesture is then a no-op rather than a
  /// stretched, soft digital crop. Everything else about it — the curve, the
  /// smoothing, the call rate — lives in [ZoomController], off the build path.
  late final ZoomController _zoom = ZoomController(
    vsync: this,
    apply: (level) async {
      await _controller?.setZoomLevel(level);
    },
  );

  /// Applied level at the moment a pinch began, so the second finger is
  /// relative rather than absolute.
  double _pinchAnchor = 1;

  _CamState _state = _CamState.preview;
  File? _capturedFile;

  /// The bake in flight, if any. _send awaits it so a filtered shot is never
  /// sent as the raw frame just because the user was quick.
  Future<File?>? _bake;

  /// While a bake is running, the review screen shows the RAW frame with this
  /// filter applied live — the same widget the viewfinder uses. Without it the
  /// photo would visibly change colour under the user when the bake lands.
  CameraFilter? _bakedPreview;
  bool _bakeMirror = false;
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
    double minZoom;
    double maxZoom;
    try {
      minZoom = await c.getMinZoomLevel();
      maxZoom = await c.getMaxZoomLevel();
    } catch (_) {
      minZoom = maxZoom = 1; // device would not say — treat as fixed
    }
    // Logged because it is a device claim we cannot check from here, and the
    // whole gesture is calibrated against it: a sub-1.0 minimum means the
    // stream is fronted by the ultra-wide, and a maximum in the tens is digital
    // crop the sensor cannot resolve.
    debugPrint('[camera] zoom range $minZoom..$maxZoom');
    _zoom.configure(min: minZoom, max: maxZoom);
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
    _zoom.dispose();
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
    // The new lens reports its own bounds; _initController reconfigures and
    // resets the level with them.
    await _initController(_cameras[_cameraIndex]); // filter is preserved
  }

  void _toggleFlash() => setState(() => _flashOn = !_flashOn);

  IconData get _flashIcon => _flashOn ? Icons.flash_on : Icons.flash_off;

  Future<void> _boostBrightness() async {
    try {
      await ScreenBrightness().setScreenBrightness(1);
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
        await Future<void>.delayed(const Duration(milliseconds: 400));
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
      final raw = File(xfile.path);

      // Show the shot IMMEDIATELY. takePicture has already written a complete,
      // viewable JPEG — waiting for the bake before putting anything on screen
      // is what made the shutter feel slow, and it showed a black veil while it
      // waited. Perceived latency is now the shutter round trip alone, however
      // long the bake takes.
      //
      // PEAK QUALITY: an unfiltered, un-mirrored shot is sent EXACTLY as the
      // camera produced it — no decode/re-encode, zero generation loss. Only
      // filtered/mirrored shots are re-processed, behind the review screen.
      final needsBake = _selectedFilter.id != 'none' || mirror;
      setState(() {
        _capturedFile = raw;
        _capturedIsVideo = false;
        _state = _CamState.captured;
        _bakedPreview = needsBake ? _selectedFilter : null;
        _bakeMirror = mirror;
      });
      if (!needsBake) return;

      final f = _selectedFilter;
      // Kept as a field so _send can await a bake that is still running instead
      // of shipping the unbaked frame the user is looking at.
      final bake = _bake = _runBake(xfile.path, f, mirror);
      final file = await bake;
      if (!mounted || _bake != bake) return; // retaken or superseded
      setState(() {
        _capturedFile = file ?? raw;
        _bakedPreview = null;
        _bake = null;
      });
      if (file != null) {
        // The sensor JPEG is now dead weight — a few MB per shot that nothing
        // else ever deleted.
        unawaited(raw.delete().catchError((_) => raw));
      }
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

  /// Runs the filter/mirror bake off-isolate and writes the result. Returns
  /// null if it fails — the caller then keeps the sensor frame, which is a
  /// worse photo than intended but never a lost one.
  Future<File?> _runBake(String path, CameraFilter f, bool mirror) async {
    try {
      final out = await compute(
        bakeSnap,
        BakeRequest(
          path: path,
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
      return file;
    } catch (e) {
      debugPrint('[camera] bake failed: $e');
      return null;
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
      if (_recordElapsed >= _maxRecord) {
        _stopRecording(); // auto-stop at the cap
      }
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
      unawaited(vp.dispose());
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
    // Drop any bake still running — its result is for a photo being thrown away.
    _bake = null;
    _bakedPreview = null;
    final f = _capturedFile;
    _capturedFile = null;
    _capturedIsVideo = false;
    final vp = _videoPreview;
    _videoPreview = null;
    unawaited(vp?.dispose());
    setState(() => _state = _CamState.preview);
    try {
      await f?.delete();
    } catch (_) {}
  }

  // ── send ──────────────────────────────────────────────────────────────────
  Future<void> _send() async {
    // A bake may still be running: the user can reach Send before it lands.
    // Wait for it rather than sending the unfiltered frame they are looking at.
    final pending = _bake;
    if (pending != null) {
      setState(() => _state = _CamState.sending);
      await pending;
      if (!mounted) return;
    }
    final file = _capturedFile;
    if (file == null) return;

    // Home check-in accepts a photo only — pop it back to the caller. A video
    // always goes to chat (below).
    if (widget.returnFile && !_capturedIsVideo) {
      Navigator.pop(context, file);
      return;
    }

    // Hand it to the queue and leave. The upload is not something the user
    // should be made to watch: on a slow connection the old code parked them
    // behind a full-screen veil for as long as the network took, and a failure
    // lost the photo outright. The queue owns it from here, so it survives this
    // screen closing — and the chat shows the bubble immediately either way.
    if (_capturedIsVideo) {
      // Video → private couple_intimate bucket + kind:'video'. The partner's
      // chat renders it from the postgres echo (no image fast-path broadcast).
      ChatSendQueue.instance.enqueueVideo(widget.coupleId, file);
    } else {
      ChatSendQueue.instance.enqueueImage(widget.coupleId, file);
    }
    widget.onSent?.call();
    Navigator.pop(context);
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
                  child: CircularProgressIndicator(color: MilesColors.ember),)
              : (_state == _CamState.preview || _state == _CamState.recording)
                  ? _buildPreview()
                  : _buildCaptured(),
    );
  }

  // ── zoom gestures ─────────────────────────────────────────────────────────
  //
  // Two ways in, one target. Neither calls setState: a rebuild of this tree per
  // pointer move is what made zoom feel like it was dragging the whole screen
  // behind it.

  void _onPinchStart(ScaleStartDetails _) => _pinchAnchor = _zoom.value.value;

  void _onPinchUpdate(ScaleUpdateDetails d) =>
      _zoom.setLevel(_pinchAnchor * d.scale);

  /// The hold was accepted: video starts and the holding finger becomes the
  /// zoom control.
  ///
  /// The tick is not decoration. Until the shutter's grow animation lands there
  /// is no signal that the hold registered, and a hold that has not visibly
  /// registered gets released — which is a 200ms video, discarded.
  void _onHoldStart() {
    unawaited(HapticFeedback.mediumImpact());
    _zoom.beginDrag();
    unawaited(_startRecording());
  }

  // ── preview state ─────────────────────────────────────────────────────────
  Widget _buildPreview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: MilesColors.ember),);
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
        // Pinch anywhere on the frame. behavior: translucent so the controls
        // stacked above still receive their own taps.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: _onPinchStart,
          onScaleUpdate: _onPinchUpdate,
          child: viewfinder,
        ),

        // The badge, and nothing else, listens to the zoom. A ValueListenable
        // instead of setState is the whole point: during a drag this rebuilds
        // one Text per frame rather than the camera tree, the preview and the
        // filter strip.
        Positioned(
          bottom: 150,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: ValueListenableBuilder<double>(
                valueListenable: _zoom.value,
                builder: (context, level, _) {
                  // Only while it differs from 1x — a permanent badge is
                  // clutter.
                  if ((level - 1).abs() < 0.01) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5,),
                    decoration: BoxDecoration(
                      // A scrim over the live preview — the zoom level has to
                      // read against whatever the lens is pointed at.
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('${level.toStringAsFixed(1)}x',
                        style: const TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,),),
                  );
                },
              ),
            ),
          ),
        ),

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

        // 3. + 4. filter name label + bottom control bar
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
      child: Container(
        color: MilesColors.surface1,
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
                          'Recording… slide up to zoom, release to stop',
                          style: TextStyle(
                              color: MilesColors.cream100, fontSize: 12,),
                        ),
                      )
                    : _filterStrip(),
              ),
              const SizedBox(height: 14),
              _CaptureButton(
                recording: recording,
                onTap: _capture,
                onHoldStart: _onHoldStart,
                onHoldMove: _zoom.dragBy,
                onHoldEnd: _stopRecording,
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
      // Until the bake lands we are showing the RAW sensor frame, so it is
      // dressed in the same filter stack the viewfinder used. The baked file
      // then swaps in underneath looking identical, instead of the photo
      // visibly changing colour a second after the shutter.
      previewFilter: _bakedPreview,
      previewMirror: _bakeMirror,
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
            child: SurfacePanel(
              glow: MilesColors.ember,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.no_photography_outlined,
                      color: MilesColors.emberSoft, size: 40,),
                  const SizedBox(height: 14),
                  Text('Camera unavailable',
                      style: Theme.of(context).textTheme.headlineSmall,),
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
                  const TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: Text('Open Settings'),
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
      // A scrim over the viewfinder or the shot being reviewed — this button
      // floats on top of both.
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
            color: MilesColors.tint(Colors.black, 0.28),
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

/// A long press for a finger that is already travelling when it matures.
///
/// Both settings are unreachable from where they are normally set.
/// [LongPressGestureRecognizer] does not forward `preAcceptSlopTolerance` to
/// [PrimaryPointerGestureRecognizer] (long_press.dart:281-290), so overriding
/// the getter is the only seam — and left at its default it resolves to
/// Android's touch slop, about 8 logical pixels. Drift further than that before
/// the deadline and the press is REJECTED: no video, and no photo either,
/// because tap rejects on the same slop. A gesture whose whole definition is
/// "move while holding" cannot live inside 8px.
///
/// 500ms, the default duration, reads as a sluggish shutter; 200ms is clear of
/// a tap and short of a wait.
class _SlidingLongPress extends LongPressGestureRecognizer {
  _SlidingLongPress() : super(duration: const Duration(milliseconds: 200));

  @override
  double? get preAcceptSlopTolerance => 40;
}

/// Tap = photo, hold = video, slide the holding finger up = zoom in.
///
/// [GestureDetector] cannot express this: it constructs its
/// [LongPressGestureRecognizer] itself and passes only `debugOwner` and
/// `supportedDevices`, so neither of the two settings this gesture turns is
/// reachable through it.
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
    this.recording = false,
  });
  final VoidCallback onTap;
  final VoidCallback onHoldStart;

  /// Upward finger travel since the press, in logical pixels.
  final ValueChanged<double> onHoldMove;
  final VoidCallback onHoldEnd;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      // Opaque so the Stack stops here. The preview's ScaleGestureRecognizer
      // claims a single-finger drag at 36px with no deadline to wait for, so if
      // a pointer on the shutter ever reached it, it would win the arena before
      // the 200ms hold matured and recording would simply never start.
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (r) => r.onTap = onTap,
        ),
        _SlidingLongPress:
            GestureRecognizerFactoryWithHandlers<_SlidingLongPress>(
          _SlidingLongPress.new,
          // The lambdas are parenthesised because an arrow body swallows a
          // following `..` into itself.
          (r) => r
            ..onLongPressStart = ((_) => onHoldStart())
            // offsetFromOrigin, not localOffsetFromOrigin: this button grows
            // 72→84 on record, and in local space that would make zoom
            // sensitivity a function of the button's own animation. Upward
            // travel is negative dy.
            ..onLongPressMoveUpdate =
                ((d) => onHoldMove(-d.offsetFromOrigin.dy))
            ..onLongPressEnd = ((_) => onHoldEnd()),
        ),
      },
      // RawGestureDetector announces nothing on its own, where GestureDetector
      // wrapped its recognisers in this for free. Without it the shutter is an
      // unlabelled blob to TalkBack.
      child: Semantics(
        button: true,
        label: 'Take photo, hold for video',
        onTap: recording ? null : onTap,
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
        // A scrim over the live preview — the elapsed time sits on the frame
        // being recorded.
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
                color: MilesColors.blush, shape: BoxShape.circle,),
          ),
          const SizedBox(width: 8),
          Text('$mm:$ss',
              style: const TextStyle(
                  color: MilesColors.cream50, fontWeight: FontWeight.w600,),),
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
              child: CircularProgressIndicator(color: MilesColors.ember),),
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
          child: _CameraBar(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: onRetake,
                  child: const Text('Retake',
                      style: TextStyle(color: MilesColors.cream100),),
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
            // A scrim over the shot being reviewed — it stays visible under
            // the spinner so you can see what is on its way.
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
    required this.imageFile, required this.annotating, required this.onAnnotateStart, required this.onAnnotateDone, required this.onAnnotateCancel, required this.onRetake, required this.onSend, required this.sending, required this.sendLabel, super.key,
    this.previewFilter,
    this.previewMirror = false,
  });

  final File imageFile;

  /// Set while a bake is still running: [imageFile] is then the RAW sensor
  /// frame, and this dresses it in the filter the viewfinder was showing so the
  /// baked file can swap in underneath without the photo changing colour.
  final CameraFilter? previewFilter;
  final bool previewMirror;
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
  /// The photo under the annotation layer.
  ///
  /// cacheWidth: decode at display size. Without it a full-resolution photo is
  /// decoded into a screen-sized box on every capture, which is why even the
  /// no-op fast path had a visible hitch.
  Widget _reviewImage(BuildContext context) {
    Widget image = Image.file(
      widget.imageFile,
      fit: BoxFit.cover,
      cacheWidth: (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context))
          .round(),
    );
    final f = widget.previewFilter;
    if (f == null) return image;
    if (widget.previewMirror) {
      image = Transform.scale(scaleX: -1, child: image);
    }
    return FilterPreviewLayer(filter: f, child: image);
  }

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
      final boundary = _captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final image = await boundary.toImage(pixelRatio: dpr);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        widget.onAnnotateDone(null);
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/annot_${DateTime.now().millisecondsSinceEpoch}.png',);
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
              _reviewImage(context),
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
                if (_strokes.isNotEmpty) {
                  _strokes.last.points.add(d.localPosition);
                }
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
            // The same scrim over the annotated shot underneath.
            color: MilesColors.ember.withValues(alpha: 0.3),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: MilesColors.cream50),
          ),
      ],
    );
  }

  Widget _reviewBar() {
    return _CameraBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: widget.onRetake,
            child: const Text('Retake',
                style: TextStyle(color: MilesColors.cream100),),
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
    return _CameraBar(
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
                        _stickers.add(_Sticker(e, const Offset(150, 280))),),
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
                    style: TextStyle(color: MilesColors.cream100),),
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
                        fontWeight: FontWeight.w600,),),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The camera's opaque bottom control bar.
///
/// Was _GlassBar, which it had not been for some time — the BackdropFilter
/// went when the blur did, and a name that describes a look the widget no
/// longer has is how the look comes back.
class _CameraBar extends StatelessWidget {
  const _CameraBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Container(
        width: double.infinity,
        color: MilesColors.surface1,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SafeArea(top: false, child: child),
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
