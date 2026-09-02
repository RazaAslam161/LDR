import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/services/touch_haptics.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_bust.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/chat/camera/rapid_camera_screen.dart' show RapidCameraScreen;
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/features/games/game_chat_panel.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/touch_map/reaction_gesture_service.dart';
import 'package:miles/features/touch_map/reaction_segment_service.dart';
import 'package:miles/features/touch_map/touch_map_repository.dart';
import 'package:miles/main.dart' show MilesApp;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:vibration/vibration.dart';
import 'package:video_player/video_player.dart';

class _PendingCameraIcon {
  const _PendingCameraIcon({required this.x, required this.y});
  final double x;
  final double y;
}

class _ActiveReactionGif {

  const _ActiveReactionGif({
    required this.mediaUrl,
    required this.owner,
    required this.x,
    required this.y,
    required this.id,
    required this.isPhoto,
    this.gesture = ReactionGesture.unknown,
    this.mirror = false,
  });
  final String mediaUrl;

  /// WHOSE body it landed on — same contract as [_ActiveTouch.owner], so the
  /// reaction renders over that person on BOTH phones. Without it a reaction
  /// followed the viewer instead of its target and appeared over the wrong
  /// partner on the receiving device.
  final String owner;
  final double x;
  final double y;
  final String id;
  final bool isPhoto;
  final ReactionGesture gesture;

  /// Mirror the media at display time. True for front-camera VIDEO (which we
  /// can't flip on the file without FFmpeg) so the played-back reaction matches
  /// the mirrored selfie preview. Photos are flipped at capture instead.
  final bool mirror;
}

class _TouchType {
  const _TouchType(this.key, this.emoji, this.label, this.color);
  final String key;
  final String emoji;
  final String label;
  final Color color;
}

/// The keys are the wire format — they go into `touch_type` on every row and
/// are read back by both phones, so they stay exactly as they are. Only the
/// label and the emoji are user-facing, and those are what changed: the app
/// used to ship 'Lick', 'Spank', 'Bite' and 'Grab' as its own vocabulary,
/// applied to a photograph of a real person. What the feature DOES is send a
/// touch to a spot; these words describe that just as accurately without the
/// app putting those particular ones in anyone's mouth.
const List<_TouchType> _types = [
  _TouchType('caress', '🫳', 'Caress', MilesColors.gilt),
  _TouchType('glow', '💫', 'Glow', MilesColors.blush),
  _TouchType('kiss', '💋', 'Kiss', Color(0xFFD45A77)),
  _TouchType('hug', '🤗', 'Hug', MilesColors.emberSoft),
  _TouchType('grab', '🤝', 'Hold', Color(0xFFC85B7A)),
  _TouchType('pinch', '🤏', 'Pinch', Color(0xFFE08AA0)),
  _TouchType('tongue', '🪶', 'Tickle', Color(0xFFE0566B)),
  _TouchType('poke', '👉', 'Poke', MilesColors.gilt),
  _TouchType('spank', '👋', 'Tap', Color(0xFFD45A77)),
  _TouchType('bite', '✨', 'Nudge', Color(0xFFB23A5A)),
];

/// A live pan/zoom frame applied to a body photo, synced to both phones so you
/// can frame the part you want to touch.
class _Frame {
  const _Frame({this.scale = 1, this.dx = 0, this.dy = 0});
  final double scale;
  final double dx;
  final double dy;
}

_TouchType _typeOf(String key) =>
    _types.firstWhere((t) => t.key == key, orElse: () => _types.first);

/// One active touch glow — [owner] is WHOSE body it landed on.
class _ActiveTouch {
  _ActiveTouch(this.id, this.owner, this.x, this.y, this.type);
  final int id;
  final String owner;
  final double x;
  final double y;
  final String type;
}

/// Both your photos live on ONE shared screen, identical on both phones. You
/// touch each other's body; the touch lands on that body on both screens in
/// real time, and the person being touched feels the haptic. You can both
/// touch at the same time. Glows are keyed to *whose body* they hit (not screen
/// position), so the two phones stay perfectly in sync.
class TouchMapScreen extends ConsumerStatefulWidget {
  const TouchMapScreen({super.key});

  @override
  ConsumerState<TouchMapScreen> createState() => _TouchMapScreenState();
}

class _TouchMapScreenState extends ConsumerState<TouchMapScreen> {
  String _type = 'glow';
  String? _coupleId;
  String? _myUid;
  String? _partnerUid;
  String? _myName;
  String? _partnerName;

  ManagedSubscription? _channel;
  final List<_ActiveTouch> _active = [];
  int _nextId = 0;

  bool _reactionModeActive = false;
  _PendingCameraIcon? _pendingCamera;
  Timer? _cameraIconTimer;
  final List<_ActiveReactionGif> _reactions = [];

  String? _myPhotoUrl;
  String? _partnerPhotoUrl;
  // Raw couple_intimate storage paths (for saving to vault — we store the path,
  // not the 1h signed URL, so the vault entry never expires).
  String? _myBodyPath;
  String? _partnerBodyPath;
  bool _uploadingPhoto = false;
  Offset? _lastPan; // throttle caress sends
  double _heat = 0; // shared warmth 0..1
  Timer? _heatTimer;

  // Live, synced pan/zoom framing per body.
  final Map<String, _Frame> _frames = {};
  String? _adjusting; // which body is currently in adjust (pan/zoom) mode
  double _frameBaseScale = 1;

  void _onFrameStart(String owner) =>
      _frameBaseScale = _frames[owner]?.scale ?? 1;

  void _onFrameUpdate(String owner, ScaleUpdateDetails d, double w, double h) {
    final f = _frames[owner] ?? const _Frame();
    final scale = (_frameBaseScale * d.scale).clamp(1.0, 4.0);
    final dx = (f.dx + d.focalPointDelta.dx / w).clamp(-0.7, 0.7);
    final dy = (f.dy + d.focalPointDelta.dy / h).clamp(-0.7, 0.7);
    setState(() => _frames[owner] = _Frame(scale: scale, dx: dx, dy: dy));
    _channel?.channel?.sendBroadcastMessage(event: 'frame', payload: {
      'from': _myUid,
      'target': owner,
      'scale': scale,
      'dx': dx,
      'dy': dy,
    },);
  }

  void _onFrameMsg(Map<String, dynamic> p) {
    if (!mounted || p['from'] == _myUid) return;
    final target = p['target']?.toString();
    if (target == null) return;
    setState(() => _frames[target] = _Frame(
          scale: (p['scale'] as num?)?.toDouble() ?? 1,
          dx: (p['dx'] as num?)?.toDouble() ?? 0,
          dy: (p['dy'] as num?)?.toDouble() ?? 0,
        ),);
  }

  /// The partner swapped their photo — reload it live (no need to leave + return).
  void _onPhotoMsg(Map<String, dynamic> p) {
    if (p['from'] == _myUid) return;
    _loadPhotos();
  }

  // ── Neon trails — glowing lines that fade like a comet tail ──
  bool _drawing =
      false; // draw-mode toggle (drag draws neon instead of touches)
  final List<_NP> _neon = [];
  int _neonId = 0;
  String? _curStroke;
  Offset? _lastNeonPt;
  Timer? _neonTimer;

  void _neonStart(String owner, double x, double y) {
    _curStroke = '$_myUid-${_neonId++}';
    _addNeon(owner, x, y, _curStroke!, mine: true);
  }

  void _neonAdd(String owner, double x, double y) {
    final s = _curStroke;
    if (s == null) return;
    if (_lastNeonPt != null && (Offset(x, y) - _lastNeonPt!).distance < 0.012) {
      return;
    }
    _addNeon(owner, x, y, s, mine: true);
  }

  void _neonEnd() {
    _curStroke = null;
    _lastNeonPt = null;
  }

  void _addNeon(String owner, double x, double y, String stroke,
      {required bool mine,}) {
    if (mine) _lastNeonPt = Offset(x, y);
    setState(() => _neon
        .add(_NP(owner, x, y, DateTime.now().millisecondsSinceEpoch, stroke)),);
    _ensureNeonTimer();
    if (mine) {
      _bumpHeat();
      _channel?.channel?.sendBroadcastMessage(event: 'neon', payload: {
        'from': _myUid,
        'owner': owner,
        'stroke': stroke,
        'x': x,
        'y': y,
      },);
    }
  }

  void _onNeonMsg(Map<String, dynamic> p) {
    if (!mounted || p['from'] == _myUid) return;
    final owner = p['owner']?.toString();
    final stroke = p['stroke']?.toString();
    final x = (p['x'] as num?)?.toDouble();
    final y = (p['y'] as num?)?.toDouble();
    if (owner == null || stroke == null || x == null || y == null) return;
    _addNeon(owner, x, y, stroke, mine: false);
  }

  void _onReactionGifMsg(Map<String, dynamic> payload) {
    if (!mounted || payload['from'] == _myUid) return;
    final mediaUrl = (payload['media_url'] ?? payload['gif_url']) as String?;
    final x = (payload['x'] as num?)?.toDouble();
    final y = (payload['y'] as num?)?.toDouble();
    final id = payload['id'] as String? ?? const Uuid().v4();
    final isPhoto = payload['is_photo'] as bool? ?? false;
    final gestureStr = payload['gesture'] as String? ?? 'unknown';
    final gesture = ReactionGesture.values.firstWhere(
      (g) => g.name == gestureStr,
      orElse: () => ReactionGesture.unknown,
    );
    final mirror = payload['mirror'] as bool? ?? false;
    // Older builds broadcast no owner. They could only react to the partner's
    // body, so on this device that target is me.
    final owner = payload['owner']?.toString() ?? _myUid;
    if (mediaUrl != null && x != null && y != null && owner != null) {
      _addReaction(
        mediaUrl: mediaUrl,
        owner: owner,
        x: x,
        y: y,
        id: id,
        isPhoto: isPhoto,
        gesture: gesture,
        mirror: mirror,
      );
    }
  }

  /// [owner] is whose body the reaction was placed on — carried all the way to
  /// the broadcast so it lands on the same person on both phones.
  Future<void> _startReactionCapture(String owner, double x, double y) async {
    // Choice: capture a fresh reaction (camera) or pick an existing photo.
    final source = await _showMediaSourceSheet();
    if (source == null || !mounted) return;

    _ReactionCapture? captured;
    if (source == 'camera') {
      captured = await _ReactionFullCamera.open(context);
    } else if (source == 'gallery_video') {
      captured = await _pickVideoFromGallery();
    } else {
      captured = await _pickPhotoFromGallery();
    }
    if (captured == null || !mounted) return;

    await _processCapturedReaction(
      file: captured.file,
      owner: owner,
      isPhoto: captured.isPhoto,
      mirror: captured.mirror,
      x: x,
      y: y,
    );
  }

  /// The full reaction pipeline: compress → gesture detect → background removal
  /// → upload → local add + broadcast to partner. Behaviour is unchanged from
  /// the previous reaction prompts; it now lives in one method so both the
  /// camera and gallery paths feed it.
  Future<void> _processCapturedReaction({
    required File file,
    required String owner,
    required bool isPhoto,
    required double x,
    required double y,
    bool mirror = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Creating your reaction… 💫'),
        duration: Duration(seconds: 20),
        behavior: SnackBarBehavior.floating,
      ),
    );

    var sourceFile = file;

    // Camera photos arrive at ResolutionPreset.max — compress to ≤1200px before
    // the heavier ML steps + upload. The decode/resize/encode runs off the UI
    // isolate via compute(); the temp-file WRITE stays on the main isolate
    // because path_provider's MethodChannel can't be reached from a background
    // isolate. Gallery photos are already sized by ImagePicker, so re-compress
    // here is cheap and harmless.
    if (isPhoto) {
      try {
        final bytes = await compute(_compressReactionPhoto, file.path);
        if (bytes != null) {
          final dir = await getTemporaryDirectory();
          final out = File(
            '${dir.path}/reaction_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          await out.writeAsBytes(bytes, flush: true);
          sourceFile = out;
        }
      } catch (_) {
        // Compression is best-effort — fall back to the original file.
      }
    }

    // Gesture detection — photos only (video needs frame extraction).
    var gesture = ReactionGesture.unknown;
    if (isPhoto) {
      gesture = await ReactionGestureService.detectGesture(sourceFile.path);
    }

    // Background removal — photos only; too slow per-frame for video.
    var processedFile = sourceFile;
    if (isPhoto) {
      final segmented =
          await ReactionSegmentService.removeBackground(sourceFile.path);
      if (segmented != null) processedFile = segmented;
    }

    final contentType = isPhoto ? 'image/png' : 'video/mp4';
    final ext = isPhoto ? 'png' : 'mp4';
    final mediaUrl = await _uploadReactionMedia(processedFile, contentType, ext);

    // Clean up every temp file we touched (deduped so we never double-delete).
    for (final p in {processedFile.path, sourceFile.path, file.path}) {
      try {
        await File(p).delete();
      } catch (_) {}
    }

    if (!mounted) return;
    messenger.hideCurrentSnackBar();

    if (mediaUrl == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not send reaction. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final reactionId = const Uuid().v4();
    _addReaction(
      mediaUrl: mediaUrl,
      owner: owner,
      x: x,
      y: y,
      id: reactionId,
      isPhoto: isPhoto,
      gesture: gesture,
      mirror: mirror,
    );

    unawaited(_channel?.channel?.sendBroadcastMessage(
      event: 'reaction_gif',
      payload: {
        'from': _myUid,
        'owner': owner,
        'media_url': mediaUrl,
        'x': x,
        'y': y,
        'id': reactionId,
        'is_photo': isPhoto,
        'gesture': gesture.name,
        'mirror': mirror,
      },
    ),);
  }

  /// Source choice sheet — 'camera' (photo or video) or 'gallery' (photo only).
  /// Returns null on cancel.
  Future<String?> _showMediaSourceSheet() {
    // Guard the cover while the sheet is up (cleared when it closes).
    MilesApp.systemOverlayActive = true;
    return showModalBottomSheet<String?>(
      context: context,
      builder: (sheetCtx) => SurfacePanel(
        radius: 24,
        padding: EdgeInsets.zero,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: MilesColors.gilt,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Send a reaction',
                  style: MilesType.fraunces(
                    fontSize: 20,
                    fontStyle: FontStyle.italic,
                    color: MilesColors.cream50,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'How do you want to react?',
                  style: MilesType.inter(
                    fontSize: 13,
                    color: MilesColors.taupe,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _SourceOption(
                        icon: Icons.photo_camera_rounded,
                        label: 'Camera',
                        subtitle: 'Photo or video',
                        onTap: () => Navigator.pop(sheetCtx, 'camera'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SourceOption(
                        icon: Icons.photo_library_rounded,
                        label: 'Photo',
                        subtitle: 'From gallery',
                        onTap: () => Navigator.pop(sheetCtx, 'gallery'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SourceOption(
                        icon: Icons.video_library_rounded,
                        label: 'Video',
                        subtitle: 'From gallery',
                        onTap: () => Navigator.pop(sheetCtx, 'gallery_video'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: MilesColors.taupe),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => MilesApp.systemOverlayActive = false);
  }

  /// Pick a single photo from the gallery (pre-sized by ImagePicker, so it skips
  /// the extra compression pass).
  Future<_ReactionCapture?> _pickPhotoFromGallery() async {
    // The system gallery picker bounces the app through `inactive`; guard the
    // News cover so we don't return from the picker onto the cover screen.
    MilesApp.systemOverlayActive = true;
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 90,
      );
      if (xfile == null) return null;
      return _ReactionCapture(file: File(xfile.path), isPhoto: true);
    } catch (_) {
      return null;
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  /// Pick a video from the gallery, capped at 10s. ImagePicker's maxDuration
  /// only limits NEW recordings (not gallery selections), and there's no FFmpeg
  /// to trim here — so we validate the duration with the video player and reject
  /// anything longer than ~10s. (The reaction also auto-fades after ~8s.)
  Future<_ReactionCapture?> _pickVideoFromGallery() async {
    final messenger = ScaffoldMessenger.of(context);
    MilesApp.systemOverlayActive = true;
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(seconds: 10),
      );
      if (xfile == null) return null;
      final file = File(xfile.path);

      // Enforce the 10s cap (no FFmpeg trim available).
      try {
        final probe = VideoPlayerController.file(file);
        await probe.initialize();
        final dur = probe.value.duration;
        await probe.dispose();
        if (dur > const Duration(seconds: 11)) {
          if (mounted) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text('Please pick a video up to 10 seconds.'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return null;
        }
      } catch (_) {
        // Couldn't read the duration — allow it; the reaction caps display ~8s.
      }

      // Gallery video is not a front-camera selfie, so no display mirror.
      return _ReactionCapture(file: file, isPhoto: false);
    } catch (_) {
      return null;
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  Future<String?> _uploadReactionMedia(
    File file,
    String contentType,
    String ext,
  ) async {
    try {
      final path = '$_coupleId/reactions/${const Uuid().v4()}.$ext';
      await SupabaseService.client.storage
          .from('couple_intimate')
          .upload(
            path,
            file,
            fileOptions: FileOptions(contentType: contentType),
          );
      return await SupabaseService.client.storage
          .from('couple_intimate')
          .createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  void _addReaction({
    required String mediaUrl,
    required String owner,
    required double x,
    required double y,
    required String id,
    required bool isPhoto,
    ReactionGesture gesture = ReactionGesture.unknown,
    bool mirror = false,
  }) {
    final r = _ActiveReactionGif(
      mediaUrl: mediaUrl,
      owner: owner,
      x: x,
      y: y,
      id: id,
      isPhoto: isPhoto,
      gesture: gesture,
      mirror: mirror,
    );
    if (mounted) setState(() => _reactions.add(r));
    _playGestureHaptic(gesture);
    Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _reactions.remove(r));
    });
  }

  void _playGestureHaptic(ReactionGesture gesture) {
    switch (gesture) {
      case ReactionGesture.palmFlat:
        Vibration.vibrate(
          pattern: [0, 80, 200, 60, 200, 80, 200, 60],
          intensities: [0, 60, 0, 50, 0, 55, 0, 50],
        );
      case ReactionGesture.pinch:
        Vibration.vibrate(
          pattern: [0, 40, 30, 40],
          intensities: [0, 255, 0, 255],
        );
      case ReactionGesture.squeeze:
        Vibration.vibrate(
          pattern: [0, 300],
          intensities: [0, 200],
        );
      case ReactionGesture.point:
        Vibration.vibrate(
          pattern: [0, 60],
          intensities: [0, 180],
        );
      case ReactionGesture.unknown:
        HapticFeedback.mediumImpact();
    }
  }

  double _reactionSize(double x, double y) {
    if (y < 0.15) return 52; // head/face
    if (y < 0.35) return 68; // neck/upper chest
    if (y < 0.65) return 80; // chest/torso
    if (y < 0.85) return 64; // waist/hips
    return 48; // legs/feet
  }

  void _ensureNeonTimer() {
    _neonTimer ??= Timer.periodic(const Duration(milliseconds: 55), (_) {
      if (!mounted) return;
      final cutoff = DateTime.now().millisecondsSinceEpoch - 1300;
      _neon.removeWhere((p) => p.t < cutoff);
      if (_neon.isEmpty) {
        _neonTimer?.cancel();
        _neonTimer = null;
      }
      setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure(); // intimate photos — block screenshots
    _heatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _heat > 0) {
        setState(() => _heat = (_heat - 0.03).clamp(0.0, 1.0));
      }
    });
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    _myUid = session.profile?.id;
    _partnerUid = session.partner?.id;
    _myName = session.profile?.displayName ?? 'You';
    _partnerName = session.partner?.displayName ?? 'Them';
    if (couple == null) return;
    _coupleId = couple.id;
    _subscribe();
    _loadPhotos();
  }

  void _subscribe() {
    final id = _coupleId;
    if (id == null) return;
    // Ephemeral, low-latency touch sync (no DB writes).
    _channel = ManagedSubscription.start(() => SupabaseService.client
        .channel('touch:$id', opts: const RealtimeChannelConfig(private: true))
        .onBroadcast(event: 'touch', callback: _onTouchMsg)
        .onBroadcast(event: 'frame', callback: _onFrameMsg)
        .onBroadcast(event: 'photo', callback: _onPhotoMsg)
        .onBroadcast(event: 'neon', callback: _onNeonMsg)
        .onBroadcast(event: 'reaction_gif', callback: _onReactionGifMsg)
        .subscribe(),);
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    _heatTimer?.cancel();
    _neonTimer?.cancel();
    _cameraIconTimer?.cancel();
    _channel?.dispose();
    super.dispose();
  }

  void _haptic(String type) => TouchHaptics.feel(type, _heat);

  void _bumpHeat() {
    if (mounted) setState(() => _heat = (_heat + 0.07).clamp(0.0, 1.0));
  }

  Future<void> _loadPhotos() async {
    final id = _coupleId;
    if (id == null) return;
    final mine = await PresenceService.fetchMine(id);
    final partner = await PresenceService.fetchPartner(id);
    final myUrl = await TouchMapRepository.signedBodyUrl(mine?.bodyPhotoPath);
    final partnerUrl =
        await TouchMapRepository.signedBodyUrl(partner?.bodyPhotoPath);
    if (mounted) {
      setState(() {
        _myPhotoUrl = myUrl;
        _partnerPhotoUrl = partnerUrl;
        _myBodyPath = mine?.bodyPhotoPath;
        _partnerBodyPath = partner?.bodyPhotoPath;
      });
    }
  }

  Future<void> _setMyPhoto() async {
    final id = _coupleId;
    if (id == null) return;
    final file = await PhotoPickerService.pickFromSheet(context);
    if (file == null) return;
    await _uploadMyPhoto(id, file);
  }

  /// Separate from the picking so the snackbar's Retry re-sends the file
  /// already chosen instead of marching the user back through the sheet.
  Future<void> _uploadMyPhoto(String id, File file) async {
    if (mounted) setState(() => _uploadingPhoto = true);
    try {
      final path = await TouchMapRepository.uploadBodyPhoto(id, file);
      if (path != null) {
        await PresenceService.setBodyPhoto(id, path);
        final url = await TouchMapRepository.signedBodyUrl(path);
        if (mounted) {
          setState(() {
            _myPhotoUrl = url;
            _myBodyPath = path;
            if (_myUid != null) {
              _frames.remove(_myUid); // fresh photo, fresh frame
            }
          });
        }
        // Tell the partner to reload my photo live.
        unawaited(_channel?.channel
            ?.sendBroadcastMessage(event: 'photo', payload: {'from': _myUid}),);
      }
    } catch (e, st) {
      // The repository used to fold every failure into null and this method
      // showed nothing for it — the spinner just stopped. Reported so the
      // fleet's failures are visible; said so this user's is.
      ErrorReporter.report(e, st, kind: 'touch');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("That photo didn't upload."),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _uploadMyPhoto(id, file),
            ),
          ),
        );
      }
    }
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  /// Remove a body photo — yours OR your partner's. Clears it here immediately,
  /// nulls it server-side (couple-scoped RPC), and tells the other phone to
  /// reload — so it disappears from both screens in real time.
  Future<void> _deletePhoto(String owner) async {
    final isMe = owner == _myUid;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: Text(
          isMe ? 'Remove your photo?' : 'Remove ${_nameOf(owner)}’s photo?',
        ),
        content: const Text(
          'It disappears from both of your screens right away.',
          style: TextStyle(color: MilesColors.taupe, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: MilesColors.emberDeep),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Optimistic: clear it here now, remember the old urls in case we must revert.
    final prevMine = _myPhotoUrl;
    final prevPartner = _partnerPhotoUrl;
    setState(() {
      if (isMe) {
        _myPhotoUrl = null;
      } else {
        _partnerPhotoUrl = null;
      }
      _frames.remove(owner);
    });
    try {
      await TouchMapRepository.deleteBodyPhoto(owner);
      // Tell the other phone to reload both photos live.
      unawaited(_channel?.channel
          ?.sendBroadcastMessage(event: 'photo', payload: {'from': _myUid}),);
    } catch (_) {
      if (mounted) {
        setState(() {
          _myPhotoUrl = prevMine;
          _partnerPhotoUrl = prevPartner;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not remove the photo.')),
        );
      }
    }
  }

  /// A quick snap — straight to the camera, no crop/confirm, sent to chat.
  Future<void> _quickSnap() async {
    final id = _coupleId;
    if (id == null) return;
    // Guard the News cover while the system camera is open.
    MilesApp.systemOverlayActive = true;
    try {
      final shot = await ImagePicker()
          .pickImage(source: ImageSource.camera, imageQuality: 70);
      if (shot == null) return;
      await ChatRepository.sendImage(id, File(shot.path));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Snap sent 📸')),
        );
      }
    } catch (_) {
      // "Snap sent 📸" is the only feedback here, so a swallowed upload was
      // indistinguishable from never having taken the photo at all.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("That snap didn't send.")),
        );
      }
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  /// Local touch on [owner]'s body at normalized (x,y): show it here, buzz a
  /// light feedback, and broadcast so it lands on their phone too.
  void _touch(String owner, double x, double y) {
    TouchHaptics.touchTick(); // light feedback for the toucher
    _bumpHeat();
    _spawn(owner, x, y, _type);
    _channel?.channel?.sendBroadcastMessage(event: 'touch', payload: {
      'from': _myUid,
      'target': owner,
      'x': x,
      'y': y,
      // 'effect', not 'type' — realtime_client overwrites a payload key called
      // 'type' with 'broadcast' before sending, so every partner has been
      // seeing the fallback effect rather than the one that was chosen.
      'effect': _type,
    },);
    // REACTION MODE ONLY — camera icon appears at touch point on partner's body.
    if (_reactionModeActive && owner == _partnerUid) {
      _cameraIconTimer?.cancel();
      setState(() => _pendingCamera = _PendingCameraIcon(x: x, y: y));
      _cameraIconTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _pendingCamera = null);
      });
    }
  }

  void _onTouchMsg(Map<String, dynamic> payload) {
    if (!mounted || payload['from'] == _myUid) return; // ignore our own echo
    final target = payload['target']?.toString();
    final x = (payload['x'] as num?)?.toDouble();
    final y = (payload['y'] as num?)?.toDouble();
    final type = payload['effect']?.toString() ?? 'glow';
    if (target == null || x == null || y == null) return;
    _spawn(target, x, y, type);
    _bumpHeat();
    if (target == _myUid) _haptic(type); // my body was touched — I feel it
  }

  void _spawn(String owner, double x, double y, String type) {
    setState(() => _active.add(_ActiveTouch(_nextId++, owner, x, y, type)));
  }

  void _remove(int id) {
    if (mounted) setState(() => _active.removeWhere((t) => t.id == id));
  }

  String? _photoOf(String uid) =>
      uid == _myUid ? _myPhotoUrl : _partnerPhotoUrl;
  String? _bodyPathOf(String uid) =>
      uid == _myUid ? _myBodyPath : _partnerBodyPath;
  String _nameOf(String uid) =>
      uid == _myUid ? (_myName ?? 'You') : (_partnerName ?? 'Them');

  @override
  Widget build(BuildContext context) {
    final me = _myUid;
    final partner = _partnerUid;
    // Deterministic order so BOTH phones render the two bodies identically.
    String? leftUid, rightUid;
    if (me != null && partner != null) {
      final ids = [me, partner]..sort();
      leftUid = ids[0];
      rightUid = ids[1];
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Touch'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        actions: [
          const PartnerHereAction(),
          GestureDetector(
            onTap: () => setState(() {
              _reactionModeActive = !_reactionModeActive;
              if (!_reactionModeActive) {
                _cameraIconTimer?.cancel();
                _pendingCamera = null;
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    color: _reactionModeActive
                        ? MilesColors.ember
                        : MilesColors.faint,
                    size: 24,
                  ),
                  if (_reactionModeActive)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: MilesColors.ember,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip:
                _drawing ? 'Drawing — tap to stop' : 'Draw a line',
            icon: Icon(Icons.gesture,
                color: _drawing ? MilesColors.ember : MilesColors.gilt,),
            onPressed: () => setState(() => _drawing = !_drawing),
          ),
          IconButton(
            tooltip: 'Quick snap',
            icon: const Icon(Icons.camera_alt, color: MilesColors.blush),
            onPressed: _quickSnap,
          ),
        ],
      ),
      body: (_coupleId == null || leftUid == null || rightUid == null)
          ? const Center(
              child: Text('Link with your partner first.',
                  style: TextStyle(color: MilesColors.taupe),),)
          : Column(
              children: [
                const SizedBox(height: 8),
                const Text(
                  'Tap anywhere on their photo. A glow lands in the same\n'
                  'spot on their screen, with a buzz. Their taps reach you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12),
                ),
                const SizedBox(height: 10),
                _typeSelector(),
                const SizedBox(height: 10),
                _warmthMeter(),
                const SizedBox(height: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Row(
                      children: [
                        Expanded(child: _bodyColumn(leftUid)),
                        const SizedBox(width: 8),
                        Expanded(child: _bodyColumn(rightUid)),
                      ],
                    ),
                  ),
                ),
                // Quick whisper strip — text each other without leaving Touch.
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  child: GameChatPanel(coupleId: _coupleId!, gameKey: 'touch'),
                ),
              ],
            ),
    );
  }

  Widget _typeSelector() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final t in _types)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: GestureDetector(
                onTap: () => setState(() => _type = t.key),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: MilesColors.tint(
                        t.color, _type == t.key ? 0.3 : 0.1,
                        over: MilesColors.night,),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: t.color
                            .withValues(alpha: _type == t.key ? 0.8 : 0.3),),
                  ),
                  child: Center(
                    child: Text('${t.emoji} ${t.label}',
                        style: const TextStyle(
                            color: MilesColors.cream50, fontSize: 13,),),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _warmthMeter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Icon(Icons.local_fire_department,
              color: MilesColors.blush.withValues(alpha: 0.4 + _heat * 0.6),
              size: 16,),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  Container(height: 8, color: MilesColors.surface1),
                  AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 400),
                    widthFactor: _heat.clamp(0.0, 1.0),
                    child: Container(
                      height: 8,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(colors: [
                          MilesColors.gilt,
                          MilesColors.blush,
                          MilesColors.ember,
                        ],),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One person's body: their photo (or a silhouette until they add one),
  /// touchable anywhere. Glows for THIS body render here on both phones.
  Widget _bodyColumn(String owner) {
    final isMe = owner == _myUid;
    final photoUrl = _photoOf(owner);
    final name = _nameOf(owner);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.18)),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            final adjusting = _adjusting == owner;
            final f = _frames[owner] ?? const _Frame();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (adjusting || _drawing)
                  ? null
                  : (d) => _touch(
                      owner,
                      (d.localPosition.dx / w).clamp(0.0, 1.0),
                      (d.localPosition.dy / h).clamp(0.0, 1.0),),
              onPanStart: (!adjusting && _drawing)
                  ? (d) => _neonStart(
                      owner,
                      (d.localPosition.dx / w).clamp(0.0, 1.0),
                      (d.localPosition.dy / h).clamp(0.0, 1.0),)
                  : null,
              onPanUpdate: adjusting
                  ? null
                  : (d) {
                      final x = (d.localPosition.dx / w).clamp(0.0, 1.0);
                      final y = (d.localPosition.dy / h).clamp(0.0, 1.0);
                      if (_drawing) {
                        _neonAdd(owner, x, y);
                      } else if (_lastPan == null ||
                          (Offset(x, y) - _lastPan!).distance > 0.05) {
                        _lastPan = Offset(x, y);
                        _touch(owner, x, y);
                      }
                    },
              onPanEnd: adjusting
                  ? null
                  : (_) => _drawing ? _neonEnd() : _lastPan = null,
              onScaleStart: adjusting ? (_) => _onFrameStart(owner) : null,
              onScaleUpdate:
                  adjusting ? (d) => _onFrameUpdate(owner, d, w, h) : null,
              child: Stack(
                fit: StackFit.expand,
                // Clip.none lets a reaction's oversized glow aura + drifting
                // sparkles spill past the zone box; the photo keeps its own
                // ClipRect below so it never bleeds outside the card.
                clipBehavior: Clip.none,
                children: [
                  // The photo, with the live (synced) pan/zoom frame applied.
                  ClipRect(
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translate(f.dx * w, f.dy * h)
                        ..scale(f.scale),
                      child: photoUrl != null
                          ? Image.network(photoUrl,
                              fit: BoxFit.cover,
                              // Decode to the box it is painted into. Without
                              // this a full-resolution phone photo is decoded
                              // and held at source size for a half-screen card
                              // — tens of MB of bitmap, and a slow first paint.
                              cacheWidth: (w *
                                      MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                              errorBuilder: (_, __, ___) =>
                                  CustomPaint(painter: _SilhouettePainter()),)
                          : CustomPaint(painter: _SilhouettePainter()),
                    ),
                  ),
                  // Neon hot-lines on THIS body — glowing trails that fade.
                  Positioned.fill(
                    child: IgnorePointer(
                      // Without this boundary the neon's 55ms repaint dirties
                      // the whole Stack, so the photo underneath is
                      // re-rasterised ~18x a second for a trail that never
                      // touches it.
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _NeonPainter(
                            _neon.where((p) => p.owner == owner).toList(),
                            DateTime.now().millisecondsSinceEpoch,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Name tag
                  Positioned(
                    top: 6,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3,),
                        decoration: BoxDecoration(
                          color: MilesColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(isMe ? '$name (you)' : name,
                            style: const TextStyle(
                                color: MilesColors.cream50, fontSize: 12,),),
                      ),
                    ),
                  ),
                  // Frame toggle — pinch/drag to set which part shows (synced).
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _adjusting = adjusting ? null : owner),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: adjusting
                              ? MilesColors.ember
                              : MilesColors.surface1,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(adjusting ? Icons.check : Icons.crop_free,
                            color: MilesColors.cream50, size: 16,),
                      ),
                    ),
                  ),
                  // Add my photo, on my own card. It used to be an icon in the
                  // app bar, three widgets away from the empty silhouette it
                  // filled — so the thing to tap was nowhere near the thing it
                  // changed. Only on my card: setting the partner's photo is
                  // not mine to do.
                  if (isMe && photoUrl == null && !adjusting)
                    Positioned.fill(
                      child: Center(
                        child: GestureDetector(
                          onTap: _uploadingPhoto ? null : _setMyPhoto,
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: MilesColors.surface1,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: MilesColors.gilt.withValues(alpha: 0.5),
                              ),
                            ),
                            child: _uploadingPhoto
                                ? const SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: MilesColors.emberSoft,),
                                  )
                                : const Icon(Icons.add,
                                    color: MilesColors.emberSoft, size: 26,),
                          ),
                        ),
                      ),
                    ),
                  // Once a photo is set, replacing it lives next to deleting it.
                  if (isMe && photoUrl != null && !adjusting)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: GestureDetector(
                        onTap: _uploadingPhoto ? null : _setMyPhoto,
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: const BoxDecoration(
                            color: MilesColors.surface1,
                            shape: BoxShape.circle,
                          ),
                          child: _uploadingPhoto
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: MilesColors.cream50,),
                                )
                              : const Icon(Icons.add,
                                  color: MilesColors.cream50, size: 16,),
                        ),
                      ),
                    ),
                  // Delete this photo (yours or theirs) — clears both screens.
                  if (photoUrl != null && !adjusting)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: GestureDetector(
                        onTap: () => _deletePhoto(owner),
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: const BoxDecoration(
                            color: MilesColors.surface1,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.delete_outline,
                              color: MilesColors.cream50, size: 16,),
                        ),
                      ),
                    ),
                  // Save this photo to the gallery (yours or theirs). Explicit
                  // user action, so allowed despite FLAG_SECURE on this screen.
                  if (photoUrl != null && !adjusting)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: MilesColors.surface1,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: SaveMediaButton(
                          onSave: () {
                            final p = _bodyPathOf(owner);
                            if (p == null) return Future.value(false);
                            return SaveMediaService.saveIntimatePhotoToVault(
                                path: p, senderName: isMe ? 'you' : name,);
                          },
                        ),
                      ),
                    ),
                  if (adjusting)
                    Positioned(
                      bottom: 10,
                      left: 6,
                      right: 6,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4,),
                          decoration: BoxDecoration(
                            // A scrim over the body photo it is explaining —
                            // the hint sits on the picture, not beside it.
                            color: MilesColors.night.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Pinch to zoom · drag to move — live',
                            style: TextStyle(
                                color: MilesColors.cream50, fontSize: 10.5,),
                          ),
                        ),
                      ),
                    ),
                  if (photoUrl == null)
                    Positioned(
                      bottom: 14,
                      left: 8,
                      right: 8,
                      child: Text(
                        isMe
                            ? 'Tap 📷 above to add your photo'
                            : 'Waiting for $name’s photo',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: MilesColors.gilt, fontSize: 11,),
                      ),
                    ),
                  // Glows that landed on THIS body.
                  for (final t in _active.where((a) => a.owner == owner))
                    Positioned(
                      key: ValueKey(t.id),
                      left: t.x * w - 45,
                      top: t.y * h - 45,
                      child: _Glow(type: t.type, onDone: () => _remove(t.id)),
                    ),
                  // ── Reaction mode overlays (partner column only) ──────────
                  if (!isMe && _reactionModeActive)
                    Positioned(
                      top: 36,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4,),
                          decoration: BoxDecoration(
                            // Another scrim over the body photo, for the same
                            // reason.
                            color: MilesColors.ember.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: MilesColors.ember.withValues(alpha: 0.4),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: MilesColors.ember,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Reaction mode',
                                style: TextStyle(
                                  color: MilesColors.ember,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (!isMe && _pendingCamera != null)
                    Positioned(
                      left: (_pendingCamera!.x * w) - 20,
                      top: (_pendingCamera!.y * h) - 20,
                      child: GestureDetector(
                        onTap: () async {
                          _cameraIconTimer?.cancel();
                          final pos = _pendingCamera!;
                          setState(() => _pendingCamera = null);
                          await _startReactionCapture(owner, pos.x, pos.y);
                        },
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.elasticOut,
                          builder: (_, v, child) =>
                              Transform.scale(scale: v, child: child),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: MilesColors.ember,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      MilesColors.ember.withValues(alpha: 0.5),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.videocam_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Owner-scoped like the glows and neon above, so a reaction
                  // renders over the SAME body on both phones.
                  ..._reactions.where((r) => r.owner == owner).map(
                      (r) => _ReactionGifWidget(
                          reaction: r,
                          containerWidth: w,
                          containerHeight: h,
                          size: _reactionSize(r.x, r.y),
                          onExpired: () {
                            if (mounted) setState(() => _reactions.remove(r));
                          },
                        ),),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One animated touch: a soft radial glow (kiss/hug add a rising emoji).
class _Glow extends StatefulWidget {
  const _Glow({required this.type, required this.onDone});
  final String type;
  final VoidCallback onDone;

  @override
  State<_Glow> createState() => _GlowState();
}

class _GlowState extends State<_Glow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _typeOf(widget.type);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = _c.value;
          final scale = 0.7 + v * 0.7;
          final opacity = (1 - v).clamp(0.0, 1.0);
          return SizedBox(
            width: 90,
            height: 90,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Transform.scale(
                  scale: scale,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        t.color.withValues(alpha: 0.6 * opacity),
                        t.color.withValues(alpha: 0),
                      ],),
                    ),
                  ),
                ),
                if (widget.type != 'glow')
                  Transform.translate(
                    offset: Offset(0, -v * 20),
                    child: Opacity(
                      opacity: opacity,
                      child:
                          Text(t.emoji, style: TextStyle(fontSize: 18 + v * 8)),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One neon point: normalized (x,y) on the body, ms timestamp, stroke key.
class _NP {
  _NP(this.owner, this.x, this.y, this.t, this.stroke);
  final String owner;
  final double x;
  final double y;
  final int t;
  final String stroke;
}

/// Glowing neon trails that fade with age — connects consecutive points of
/// the same stroke; newer segments are brighter (a comet tail).
class _NeonPainter extends CustomPainter {
  _NeonPainter(this.points, this.now);
  final List<_NP> points;
  final int now;

  static const _life = 1300; // ms
  static const _neon = Color(0xFFFF4D8D);

  // Hoisted and mutated in place. These were built fresh per segment per
  // frame: with a long trail that is hundreds of Paint allocations ~18x a
  // second, and MaskFilter.blur is not cheap to construct. Same pattern as
  // _EmberPainter in ember_background.dart.
  static final Paint _glowPaint = Paint()
    ..strokeWidth = 14
    ..strokeCap = StrokeCap.round
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
  static final Paint _corePaint = Paint()
    ..strokeWidth = 3.5
    ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas c, Size s) {
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      if (a.stroke != b.stroke) continue; // don't bridge separate strokes
      final age = now - b.t;
      if (age > _life) continue;
      final op = (1 - age / _life).clamp(0.0, 1.0);
      final p1 = Offset(a.x * s.width, a.y * s.height);
      final p2 = Offset(b.x * s.width, b.y * s.height);
      c.drawLine(p1, p2, _glowPaint..color = _neon.withValues(alpha: 0.35 * op));
      c.drawLine(
          p1,
          p2,
          _corePaint
            ..color =
                Color.lerp(_neon, Colors.white, 0.4)!.withValues(alpha: op),);
    }
  }

  @override
  bool shouldRepaint(covariant _NeonPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reaction GIF widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ReactionGifWidget extends StatefulWidget {

  const _ReactionGifWidget({
    required this.reaction,
    required this.containerWidth,
    required this.containerHeight,
    required this.size,
    required this.onExpired,
  });
  final _ActiveReactionGif reaction;
  final double containerWidth;
  final double containerHeight;
  final double size;
  final VoidCallback onExpired;

  @override
  State<_ReactionGifWidget> createState() => _ReactionGifWidgetState();
}

class _ReactionGifWidgetState extends State<_ReactionGifWidget>
    with TickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  VideoPlayerController? _vpc;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1,
    );

    if (!widget.reaction.isPhoto) {
      _vpc = VideoPlayerController.networkUrl(
        Uri.parse(widget.reaction.mediaUrl),
      )..initialize().then((_) {
          if (mounted) {
            setState(() => _videoReady = true);
            _vpc!
              ..setLooping(true)
              ..play();
          }
        });
    }

    final displayMs = 5000 + (widget.reaction.id.hashCode.abs() % 3000);
    Future.delayed(Duration(milliseconds: displayMs), () {
      if (mounted) {
        _fadeCtrl.reverse().then((_) {
          if (mounted) widget.onExpired();
        });
      }
    });
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _vpc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size; // zone-specific size
    final pixelX = widget.reaction.x * widget.containerWidth;
    final pixelY = widget.reaction.y * widget.containerHeight;

    // Plain content: the photo, or the looping video, shown clearly at full
    // opacity (no shapes, no transparency, no overlays).
    Widget media;
    if (widget.reaction.isPhoto) {
      media = Image.network(
        widget.reaction.mediaUrl,
        width: s,
        height: s,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const ColoredBox(
          color: MilesColors.surface1,
          child: Icon(Icons.broken_image_outlined, color: MilesColors.ember),
        ),
      );
    } else if (_videoReady && _vpc != null) {
      media = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _vpc!.value.size.width,
          height: _vpc!.value.size.height,
          child: VideoPlayer(_vpc!),
        ),
      );
      // Front-camera selfie video: mirror so it matches the sender's preview.
      if (widget.reaction.mirror) {
        media = Transform.scale(scaleX: -1, child: media);
      }
    } else {
      media = const ColoredBox(
        color: MilesColors.surface1,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: MilesColors.ember,
          ),
        ),
      );
    }

    return Positioned(
      left: (pixelX - s / 2).clamp(0.0, widget.containerWidth - s),
      top: (pixelY - s / 2).clamp(0.0, widget.containerHeight - s),
      child: FadeTransition(
        opacity: _fadeCtrl,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.3, end: 1),
          duration: const Duration(milliseconds: 400),
          curve: Curves.elasticOut,
          builder: (_, v, child) =>
              Transform.scale(scale: v, child: child),
          child: Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: MilesColors.ember.withValues(alpha: 0.7),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: MilesColors.ember.withValues(alpha: 0.35),
                  blurRadius: 14,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: media,
            ),
          ),
        ),
      ),
    );
  }
}

/// The captured reaction media handed back from the camera or gallery.
class _ReactionCapture {

  const _ReactionCapture({
    required this.file,
    required this.isPhoto,
    this.mirror = false,
  });
  final File file;
  final bool isPhoto;

  /// Display-mirror this media when it's shown as a reaction. Set for
  /// front-camera VIDEO (photos are flipped on the file at capture instead).
  final bool mirror;
}

/// One option tile in the reaction source sheet (Camera / Gallery).
class _SourceOption extends StatelessWidget {

  const _SourceOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SurfacePanel(
        elevated: true,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: MilesColors.ember, size: 30),
            const SizedBox(height: 10),
            Text(
              label,
              style: MilesType.fraunces(
                fontSize: 15,
                color: MilesColors.cream50,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: MilesType.inter(
                fontSize: 11,
                color: MilesColors.taupe,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen reaction camera — the same capture quality and layout language
/// as the chat [RapidCameraScreen], minus the filter strip. Photo + 5s video.
class _ReactionFullCamera extends StatefulWidget {
  const _ReactionFullCamera();

  static Future<_ReactionCapture?> open(BuildContext context) async {
    // The camera/mic permission dialogs make the app `inactive`; guard the
    // News cover for the whole camera session so it can't slip in underneath.
    MilesApp.systemOverlayActive = true;
    try {
      return await Navigator.of(context).push<_ReactionCapture>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const _ReactionFullCamera(),
        ),
      );
    } finally {
      MilesApp.systemOverlayActive = false;
    }
  }

  @override
  State<_ReactionFullCamera> createState() => _ReactionFullCameraState();
}

class _ReactionFullCameraState extends State<_ReactionFullCamera>
    with WidgetsBindingObserver {
  CameraController? _ctrl;
  List<CameraDescription> _cameras = const [];
  int _camIndex = 1; // front camera default
  bool _isVideoMode = false; // photo default
  bool _recording = false;
  int _countdown = 5;
  Timer? _countdownTimer;
  FlashMode _flash = FlashMode.off;
  bool _ready = false;
  bool _denied = false;
  bool _micGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    // Request camera permission up front so a denial is detected cleanly
    // (same approach as RapidCameraScreen — avoids a hung loading wheel).
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (mounted) setState(() => _denied = true);
        return;
      }
      // Mic powers video sound; non-fatal if denied (records silent). Gating
      // enableAudio on the grant avoids init failures on some OEMs.
      final mic = await Permission.microphone.request();
      _micGranted = mic.isGranted;
    } catch (_) {
      // fall through to availableCameras — it'll flag denied if truly blocked
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _denied = true);
        return;
      }
      // Default to the front (selfie) lens.
      final front = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      _camIndex = front >= 0 ? front : 0;
      await _initController(_cameras[_camIndex]);
    } catch (_) {
      if (mounted) setState(() => _denied = true);
    }
  }

  Future<void> _initController(CameraDescription cam) async {
    // Prefer veryHigh (~1080p) for a crisp reaction, fall back to high (~720p)
    // if the device can't initialise it. NO imageFormatGroup: forcing
    // ImageFormatGroup.jpeg made the plugin convert every preview frame and lag
    // these phones; takePicture still writes a JPEG regardless.
    CameraController make(ResolutionPreset preset) =>
        CameraController(cam, preset, enableAudio: _micGranted);

    var c = make(ResolutionPreset.veryHigh);
    _ctrl = c;
    try {
      await c.initialize().timeout(const Duration(seconds: 12));
    } catch (_) {
      // veryHigh unsupported / failed — retry at high.
      try {
        await c.dispose();
      } catch (_) {}
      c = make(ResolutionPreset.high);
      _ctrl = c;
      try {
        await c.initialize().timeout(const Duration(seconds: 12));
      } catch (_) {
        if (mounted) setState(() => _denied = true);
        return;
      }
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    try {
      await c.setFlashMode(_flash);
    } catch (_) {}
    setState(() => _ready = true);
  }

  bool get _isFront =>
      _cameras.isNotEmpty &&
      _cameras[_camIndex].lensDirection == CameraLensDirection.front;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _ctrl = null;
      c.dispose();
      if (mounted) setState(() => _ready = false);
    } else if (state == AppLifecycleState.resumed && _cameras.isNotEmpty) {
      _initController(_cameras[_camIndex]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  void _cycleFlash() {
    setState(() {
      _flash = _flash == FlashMode.off
          ? FlashMode.auto
          : _flash == FlashMode.auto
              ? FlashMode.always
              : FlashMode.off;
    });
    _applyFlash();
  }

  Future<void> _applyFlash() async {
    try {
      await _ctrl?.setFlashMode(_flash);
    } catch (_) {}
  }

  IconData get _flashIcon => _flash == FlashMode.off
      ? Icons.flash_off
      : _flash == FlashMode.auto
          ? Icons.flash_auto
          : Icons.flash_on;

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _recording) return;
    setState(() => _ready = false);
    await _ctrl?.dispose();
    _ctrl = null;
    _camIndex = (_camIndex + 1) % _cameras.length;
    await _initController(_cameras[_camIndex]);
  }

  Future<void> _capturePhoto() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) return;
    try {
      await _applyFlash();
      final xfile = await c.takePicture();
      final file = File(xfile.path);

      // The front camera saves the RAW (un-mirrored) frame, but the user
      // composed the shot against a mirrored preview — flip the saved photo so
      // the partner sees what the sender saw. Back camera is left as-is; video
      // is never flipped (its orientation metadata handles that).
      if (_isFront) {
        try {
          final decoded = img.decodeImage(await file.readAsBytes());
          if (decoded != null) {
            await file.writeAsBytes(
              img.encodeJpg(img.flipHorizontal(decoded), quality: 95),
            );
          }
        } catch (_) {
          // Keep the un-flipped capture on any failure.
        }
      }

      if (mounted) {
        Navigator.of(context).pop(
          _ReactionCapture(file: file, isPhoto: true),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not take that photo.')),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    final c = _ctrl;
    if (c == null ||
        !c.value.isInitialized ||
        _recording ||
        c.value.isRecordingVideo) {
      return;
    }
    setState(() {
      _recording = true;
      _countdown = 5;
    });
    try {
      await c.startVideoRecording();
    } catch (_) {
      if (mounted) setState(() => _recording = false);
      return;
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        await _stopRecording();
      }
    });
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _recording = false; // guard against the timer + a manual tap racing
    _countdownTimer?.cancel();
    _countdownTimer = null;
    final XFile xfile;
    try {
      xfile = await _ctrl!.stopVideoRecording();
    } catch (_) {
      if (mounted) setState(() {});
      return;
    }
    if (mounted) {
      Navigator.of(context).pop(
        // Front-camera video can't be flipped on the file (no FFmpeg), so flag
        // it to mirror at display — matching the mirrored selfie preview.
        _ReactionCapture(
          file: File(xfile.path),
          isPhoto: false,
          mirror: _isFront,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _denied
          ? _buildDenied()
          : (!_ready || _ctrl == null || !_ctrl!.value.isInitialized)
              ? const Center(
                  child: CircularProgressIndicator(color: MilesColors.ember),
                )
              : _buildCamera(),
    );
  }

  Widget _buildDenied() {
    return Stack(
      children: [
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _camCircleBtn(
                Icons.arrow_back,
                () => Navigator.of(context).pop(),
              ),
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
                  Text(
                    'Camera access needed',
                    style: MilesType.fraunces(
                      fontSize: 18,
                      color: MilesColors.cream50,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Allow camera access to send a reaction.',
                    textAlign: TextAlign.center,
                    style: MilesType.inter(
                      fontSize: 13,
                      color: MilesColors.taupe,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: Text(
                      'Open Settings',
                      style: TextStyle(color: MilesColors.emberSoft),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCamera() {
    final c = _ctrl!;
    Widget preview = FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c.value.previewSize?.height ?? 1080,
        height: c.value.previewSize?.width ?? 1920,
        child: CameraPreview(c),
      ),
    );
    if (_isFront) {
      // Mirror the front preview (selfie). Matrix4 scale(-1,1,1) is more
      // reliable across devices than Transform.scale(scaleX: -1).
      preview = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scale(-1.0, 1, 1),
        child: preview,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        SizedBox.expand(child: preview),

        // Top chrome — back, flash, flip.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _camCircleBtn(
                  Icons.arrow_back,
                  () => Navigator.of(context).pop(),
                ),
                if (!_recording)
                  Row(
                    children: [
                      _camCircleBtn(_flashIcon, _cycleFlash),
                      const SizedBox(width: 8),
                      if (_cameras.length > 1)
                        _camCircleBtn(
                          Icons.flip_camera_android,
                          _flipCamera,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),

        // Bottom controls — mode pill + capture button.
        Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_recording) _modePill(),
              const SizedBox(height: 12),
              _bottomBar(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modePill() {
    return GestureDetector(
      onTap: () => setState(() => _isVideoMode = !_isVideoMode),
      child: SurfacePill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isVideoMode ? '🎥' : '📷',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(width: 6),
            Text(
              _isVideoMode ? 'Video' : 'Photo',
              style: MilesType.inter(
                color: MilesColors.cream50,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return ClipRect(
      child: Container(
        width: double.infinity,
        color: MilesColors.surface1,
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_recording)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '0:${_countdown.toString().padLeft(2, '0')}',
                    style: MilesType.inter(
                      color: MilesColors.cream50,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              _captureButton(),
              if (!_recording)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _isVideoMode ? 'Tap to record · 5s' : 'Tap for photo',
                    style: const TextStyle(
                      color: MilesColors.taupe,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _captureButton() {
    // Photo — ember gradient circle.
    if (!_isVideoMode) {
      return GestureDetector(
        onTap: _capturePhoto,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: MilesGradients.cta,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: MilesColors.ember.withValues(alpha: 0.5),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
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
    // Video, idle — white ring + white dot.
    if (!_recording) {
      return GestureDetector(
        onTap: _startRecording,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: MilesColors.cream50, width: 4),
          ),
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                color: MilesColors.cream50,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      );
    }
    // Video, recording — red border + red square.
    return GestureDetector(
      onTap: _stopRecording,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.red, width: 4),
        ),
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
  }

  Widget _camCircleBtn(IconData icon, VoidCallback onTap) {
    return Material(
      // A scrim over the camera view these controls sit on.
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

/// Decode → resize to ≤1200px wide → re-encode JPEG (q90). Runs in a background
/// isolate via compute(); returns the encoded bytes (NOT a File) because
/// path_provider can't be reached from a background isolate. Returns null on any
/// failure so the caller falls back to the original image.
Uint8List? _compressReactionPhoto(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    if (image.width > 1200) {
      image = img.copyResize(image, width: 1200);
    }
    return img.encodeJpg(image, quality: 90);
  } catch (_) {
    return null;
  }
}

/// A simple, gender-neutral illustrated figure — the placeholder until a real
/// photo is added.
class _SilhouettePainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final w = s.width;
    final h = s.height;
    final fill = Paint()
      ..color = MilesColors.surface1.withValues(alpha: 0.65)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = MilesColors.gilt.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final limb = Paint()
      ..color = MilesColors.surface1.withValues(alpha: 0.65)
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round;

    c
      ..drawLine(Offset(w * 0.40, h * 0.23), Offset(w * 0.25, h * 0.47), limb)
      ..drawLine(Offset(w * 0.60, h * 0.23), Offset(w * 0.75, h * 0.47), limb)
      ..drawLine(Offset(w * 0.46, h * 0.50), Offset(w * 0.43, h * 0.92), limb)
      ..drawLine(Offset(w * 0.54, h * 0.50), Offset(w * 0.57, h * 0.92), limb);

    c.drawLine(
      Offset(w * 0.5, h * 0.135),
      Offset(w * 0.5, h * 0.19),
      Paint()
        ..color = fill.color
        ..strokeWidth = w * 0.055
        ..strokeCap = StrokeCap.round,
    );

    final torso = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.37, h * 0.18, w * 0.26, h * 0.34),
      Radius.circular(w * 0.11),
    );
    c
      ..drawRRect(torso, fill)
      ..drawRRect(torso, stroke);

    final head = Offset(w * 0.5, h * 0.09);
    c
      ..drawCircle(head, w * 0.07, fill)
      ..drawCircle(head, w * 0.07, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
