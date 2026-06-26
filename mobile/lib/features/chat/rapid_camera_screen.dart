import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:geolocator/geolocator.dart';
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

enum _CamState { preview, captured, sending }

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
  FlashMode _flash = FlashMode.auto;

  CameraFilter _selectedFilter =
      kCameraFilters.firstWhere((f) => f.id == 'freesia');

  _CamState _state = _CamState.preview;
  File? _capturedFile;
  bool _annotating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _denied = true);
        return;
      }
      // Default to the FRONT camera (selfie — the common couple snap).
      _cameraIndex = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _initController(_cameras[_cameraIndex]);
    } on CameraException {
      if (mounted) setState(() => _denied = true);
    } catch (_) {
      if (mounted) setState(() => _denied = true);
    }
  }

  Future<void> _initController(CameraDescription camera) async {
    final c = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = c;
    try {
      await c.initialize();
      await c.setFlashMode(_flash);
      if (mounted) setState(() => _ready = true);
    } on CameraException {
      if (mounted) setState(() => _denied = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    // Release the camera when backgrounded; re-init on return (avoids the
    // platform "camera in use"/black-preview crash).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _ready = false;
      c.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed && _cameras.isNotEmpty) {
      _initController(_cameras[_cameraIndex]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // ── camera controls ───────────────────────────────────────────────────────
  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _ready = false);
    await _controller?.dispose();
    _controller = null;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initController(_cameras[_cameraIndex]); // filter is preserved
  }

  Future<void> _cycleFlash() async {
    const order = [
      FlashMode.auto,
      FlashMode.always,
      FlashMode.off,
      FlashMode.torch
    ];
    final next = order[(order.indexOf(_flash) + 1) % order.length];
    setState(() => _flash = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (_) {}
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        FlashMode.off => Icons.flash_off,
        FlashMode.torch => Icons.highlight,
      };

  // ── capture + bake ────────────────────────────────────────────────────────
  Future<void> _capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) return;
    setState(
        () => _state = _CamState.captured); // shows a brief processing veil
    try {
      final xfile = await c.takePicture();
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
        ),
      );
      final dir = await getTemporaryDirectory();
      final file =
          File('${dir.path}/snap_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(out, flush: true);
      if (!mounted) return;
      setState(() {
        _capturedFile = file;
        _state = _CamState.captured;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _state = _CamState.preview);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not take that photo.')),
        );
      }
    }
  }

  Future<void> _retake() async {
    final f = _capturedFile;
    _capturedFile = null;
    setState(() => _state = _CamState.preview);
    try {
      await f?.delete();
    } catch (_) {}
  }

  // ── send ──────────────────────────────────────────────────────────────────
  Future<void> _send() async {
    final file = _capturedFile;
    if (file == null) return;

    if (widget.returnFile) {
      Navigator.pop(context, file); // home check-in path uploads it itself
      return;
    }

    setState(() => _state = _CamState.sending);
    try {
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
          ? _PermissionDenied()
          : !_ready && _state == _CamState.preview
              ? const Center(
                  child: CircularProgressIndicator(color: MilesColors.ember))
              : _state == _CamState.preview
                  ? _buildPreview()
                  : _buildCaptured(),
    );
  }

  // ── preview state ─────────────────────────────────────────────────────────
  Widget _buildPreview() {
    final c = _controller!;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. live filtered viewfinder
        FilterPreviewLayer(
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
        ),

        // 2. top bar
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
                    _RoundIcon(icon: _flashIcon, onTap: _cycleFlash),
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

        // 3. + 4. filter name label + bottom glass panel
        Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FilterNameLabel(filter: _selectedFilter),
              const SizedBox(height: 10),
              _bottomPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bottomPanel() {
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
                SizedBox(height: 72, child: _filterStrip()),
                const SizedBox(height: 14),
                _CaptureButton(onTap: _capture),
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
          recommended: f.id == 'freesia',
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

class _PermissionDenied extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
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
              Text('Camera access needed',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text(
                'Allow camera access to send a quick snap.',
                textAlign: TextAlign.center,
                style: TextStyle(color: MilesColors.taupe),
              ),
              const SizedBox(height: 18),
              GlowButton(
                label: 'Open Settings',
                expand: false,
                onPressed: Geolocator.openAppSettings,
              ),
            ],
          ),
        ),
      ),
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
    required this.recommended,
    required this.onTap,
  });

  final CameraFilter filter;
  final bool selected;
  final bool recommended;
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
            boxShadow: recommended
                ? [
                    BoxShadow(
                      color: MilesColors.ember.withValues(alpha: 0.55),
                      blurRadius: 8,
                    ),
                  ]
                : null,
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
  const _CaptureButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: MilesGradients.cta,
          boxShadow: [BoxShadow(color: MilesColors.ember, blurRadius: 16)],
        ),
        child: Center(
          child: Container(
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
