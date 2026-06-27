import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/services/touch_haptics.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/features/games/game_chat_panel.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/touch_map/touch_map_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

class _PendingCameraIcon {
  final double x;
  final double y;
  const _PendingCameraIcon({required this.x, required this.y});
}

enum _CameraMode { photo, video }

class _ActiveReactionGif {
  final String mediaUrl;
  final double x;
  final double y;
  final String id;
  final bool isPhoto;
  const _ActiveReactionGif({
    required this.mediaUrl,
    required this.x,
    required this.y,
    required this.id,
    required this.isPhoto,
  });
}

class _TouchType {
  const _TouchType(this.key, this.emoji, this.label, this.color);
  final String key;
  final String emoji;
  final String label;
  final Color color;
}

const List<_TouchType> _types = [
  _TouchType('caress', '🫳', 'Caress', MilesColors.gilt),
  _TouchType('glow', '💫', 'Glow', MilesColors.blush),
  _TouchType('kiss', '💋', 'Kiss', Color(0xFFD45A77)),
  _TouchType('hug', '🤗', 'Hug', MilesColors.emberSoft),
  _TouchType('grab', '✊', 'Grab', Color(0xFFC85B7A)),
  _TouchType('pinch', '🤏', 'Pinch', Color(0xFFE08AA0)),
  _TouchType('tongue', '👅', 'Lick', Color(0xFFE0566B)),
  _TouchType('poke', '👉', 'Poke', MilesColors.gilt),
  _TouchType('spank', '🖐️', 'Spank', Color(0xFFD45A77)),
  _TouchType('bite', '🫦', 'Bite', Color(0xFFB23A5A)),
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
    });
  }

  void _onFrameMsg(Map<String, dynamic> p) {
    if (!mounted || p['from'] == _myUid) return;
    final target = p['target']?.toString();
    if (target == null) return;
    setState(() => _frames[target] = _Frame(
          scale: (p['scale'] as num?)?.toDouble() ?? 1,
          dx: (p['dx'] as num?)?.toDouble() ?? 0,
          dy: (p['dy'] as num?)?.toDouble() ?? 0,
        ));
  }

  /// The partner swapped their photo — reload it live (no need to leave + return).
  void _onPhotoMsg(Map<String, dynamic> p) {
    if (p['from'] == _myUid) return;
    _loadPhotos();
  }

  // ── Neon "hot lines" — draw glowing trails that fade like a comet tail ──
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
      {required bool mine}) {
    if (mine) _lastNeonPt = Offset(x, y);
    setState(() => _neon
        .add(_NP(owner, x, y, DateTime.now().millisecondsSinceEpoch, stroke)));
    _ensureNeonTimer();
    if (mine) {
      _bumpHeat();
      _channel?.channel?.sendBroadcastMessage(event: 'neon', payload: {
        'from': _myUid,
        'owner': owner,
        'stroke': stroke,
        'x': x,
        'y': y,
      });
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
    // Support new 'media_url' key; fall back to legacy 'gif_url'.
    final mediaUrl = (payload['media_url'] ?? payload['gif_url']) as String?;
    final x = (payload['x'] as num?)?.toDouble();
    final y = (payload['y'] as num?)?.toDouble();
    final id = payload['id'] as String? ?? const Uuid().v4();
    final isPhoto = payload['is_photo'] as bool? ?? false;
    if (mediaUrl != null && x != null && y != null) {
      _addReaction(mediaUrl: mediaUrl, x: x, y: y, id: id, isPhoto: isPhoto);
    }
  }

  Future<void> _startReactionCapture(double x, double y) async {
    final messenger = ScaffoldMessenger.of(context);

    final mode = await _showCameraChoice(context);
    if (mode == null || !mounted) return;

    final mediaFile = mode == _CameraMode.photo
        ? await _ReactionCameraSheet.showPhoto(context)
        : await _ReactionCameraSheet.showVideo(context);
    if (mediaFile == null || !mounted) return;

    messenger.showSnackBar(
      const SnackBar(
        content: Text('Sending your reaction... 🎬'),
        duration: Duration(seconds: 15),
        behavior: SnackBarBehavior.floating,
      ),
    );

    final isPhoto = mode == _CameraMode.photo;
    final mediaUrl = await _uploadReactionMedia(
      mediaFile,
      isPhoto ? 'image/jpeg' : 'video/mp4',
      isPhoto ? 'jpg' : 'mp4',
    );
    try {
      await mediaFile.delete();
    } catch (_) {}

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
      x: x,
      y: y,
      id: reactionId,
      isPhoto: isPhoto,
    );

    _channel?.channel?.sendBroadcastMessage(
      event: 'reaction_gif',
      payload: {
        'from': _myUid,
        'media_url': mediaUrl,
        'x': x,
        'y': y,
        'id': reactionId,
        'is_photo': isPhoto,
      },
    );
  }

  Future<_CameraMode?> _showCameraChoice(BuildContext ctx) {
    return showModalBottomSheet<_CameraMode>(
      context: ctx,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassPanel(
        blur: MilesColors.blurLg,
        radius: 24,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
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
              'React with…',
              style: GoogleFonts.fraunces(
                color: MilesColors.cream50,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _reactionChoiceBtn(
                    sheetCtx,
                    Icons.photo_camera_rounded,
                    'Photo',
                    _CameraMode.photo,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _reactionChoiceBtn(
                    sheetCtx,
                    Icons.videocam_rounded,
                    'Video (5s)',
                    _CameraMode.video,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _reactionChoiceBtn(
    BuildContext ctx,
    IconData icon,
    String label,
    _CameraMode mode,
  ) {
    return GestureDetector(
      onTap: () => Navigator.of(ctx).pop(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: MilesColors.ember.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: MilesColors.ember.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: MilesColors.ember, size: 32),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(color: MilesColors.cream50, fontSize: 14),
            ),
          ],
        ),
      ),
    );
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
            fileOptions: FileOptions(contentType: contentType, upsert: false),
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
    required double x,
    required double y,
    required String id,
    required bool isPhoto,
  }) {
    final r = _ActiveReactionGif(
      mediaUrl: mediaUrl,
      x: x,
      y: y,
      id: id,
      isPhoto: isPhoto,
    );
    if (mounted) setState(() => _reactions.add(r));
    Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _reactions.remove(r));
    });
  }

  double _reactionSize(double x, double y) {
    if (y < 0.15) return 52; // head/face
    if (y < 0.35) return 68; // neck/upper chest
    if (y < 0.65) return 80; // chest/torso
    if (y < 0.85) return 64; // waist/hips
    return 48; // legs/feet
  }

  double _reactionBorderRadius(double y) {
    if (y < 0.15) return 999; // face → full circle
    if (y < 0.35) return 20; // neck → rounded pill
    return 14; // elsewhere → card
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
    reportScreen(ref, 'Touch');
    _loadPhotos();
  }

  void _subscribe() {
    final id = _coupleId;
    if (id == null) return;
    // Ephemeral, low-latency touch sync (no DB writes).
    _channel = ManagedSubscription.start(() => SupabaseService.client
        .channel('touch:$id')
        .onBroadcast(event: 'touch', callback: _onTouchMsg)
        .onBroadcast(event: 'frame', callback: _onFrameMsg)
        .onBroadcast(event: 'photo', callback: _onPhotoMsg)
        .onBroadcast(event: 'neon', callback: _onNeonMsg)
        .onBroadcast(event: 'reaction_gif', callback: _onReactionGifMsg)
        .subscribe());
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    _heatTimer?.cancel();
    _neonTimer?.cancel();
    _cameraIconTimer?.cancel();
    reportActiveTab(ref);
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
    setState(() => _uploadingPhoto = true);
    final path = await TouchMapRepository.uploadBodyPhoto(id, file);
    if (path != null) {
      await PresenceService.setBodyPhoto(id, path);
      final url = await TouchMapRepository.signedBodyUrl(path);
      if (mounted) {
        setState(() {
          _myPhotoUrl = url;
          _myBodyPath = path;
          if (_myUid != null)
            _frames.remove(_myUid); // fresh photo, fresh frame
        });
      }
      // Tell the partner to reload my photo live.
      _channel?.channel
          ?.sendBroadcastMessage(event: 'photo', payload: {'from': _myUid});
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
              child: const Text('Cancel')),
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
      _channel?.channel
          ?.sendBroadcastMessage(event: 'photo', payload: {'from': _myUid});
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
    } catch (_) {}
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
      'type': _type,
    });
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
    final type = payload['type']?.toString() ?? 'glow';
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
    final me = _myUid, partner = _partnerUid;
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
                _drawing ? 'Drawing hot lines — tap to stop' : 'Draw hot lines',
            icon: Icon(Icons.gesture,
                color: _drawing ? MilesColors.ember : MilesColors.gilt),
            onPressed: () => setState(() => _drawing = !_drawing),
          ),
          IconButton(
            tooltip: 'Quick snap',
            icon: const Icon(Icons.camera_alt, color: MilesColors.blush),
            onPressed: _quickSnap,
          ),
          IconButton(
            tooltip: 'Set my photo',
            icon: _uploadingPhoto
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_a_photo_outlined,
                    color: MilesColors.emberSoft),
            onPressed: _uploadingPhoto ? null : _setMyPhoto,
          ),
        ],
      ),
      body: (_coupleId == null || leftUid == null || rightUid == null)
          ? const Center(
              child: Text('Link with your partner first.',
                  style: TextStyle(color: MilesColors.taupe)))
          : Column(
              children: [
                const SizedBox(height: 8),
                const Text(
                  'Touch each other. They feel where you touch them —\n'
                  'you feel where they touch you. Both at once.',
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
                    color:
                        t.color.withValues(alpha: _type == t.key ? 0.3 : 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: t.color
                            .withValues(alpha: _type == t.key ? 0.8 : 0.3)),
                  ),
                  child: Center(
                    child: Text('${t.emoji} ${t.label}',
                        style: const TextStyle(
                            color: MilesColors.cream50, fontSize: 13)),
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
              size: 16),
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
                        ]),
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
          color: MilesColors.surface1.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.18)),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth, h = c.maxHeight;
            final adjusting = _adjusting == owner;
            final f = _frames[owner] ?? const _Frame();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (adjusting || _drawing)
                  ? null
                  : (d) => _touch(
                      owner,
                      (d.localPosition.dx / w).clamp(0.0, 1.0),
                      (d.localPosition.dy / h).clamp(0.0, 1.0)),
              onPanStart: (!adjusting && _drawing)
                  ? (d) => _neonStart(
                      owner,
                      (d.localPosition.dx / w).clamp(0.0, 1.0),
                      (d.localPosition.dy / h).clamp(0.0, 1.0))
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
                              errorBuilder: (_, __, ___) =>
                                  CustomPaint(painter: _SilhouettePainter()))
                          : CustomPaint(painter: _SilhouettePainter()),
                    ),
                  ),
                  // Neon hot-lines on THIS body — glowing trails that fade.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _NeonPainter(
                          _neon.where((p) => p.owner == owner).toList(),
                          DateTime.now().millisecondsSinceEpoch,
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
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: MilesColors.night.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(isMe ? '$name (you)' : name,
                            style: const TextStyle(
                                color: MilesColors.cream50, fontSize: 12)),
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
                              : MilesColors.night.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(adjusting ? Icons.check : Icons.crop_free,
                            color: MilesColors.cream50, size: 16),
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
                          decoration: BoxDecoration(
                            color: MilesColors.night.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.delete_outline,
                              color: MilesColors.cream50, size: 16),
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
                          color: MilesColors.night.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: SaveMediaButton(
                          size: 20,
                          onSave: () {
                            final p = _bodyPathOf(owner);
                            if (p == null) return Future.value(false);
                            return SaveMediaService.saveIntimatePhotoToVault(
                                path: p, senderName: isMe ? 'you' : name);
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
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: MilesColors.night.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Pinch to zoom · drag to move — live',
                            style: TextStyle(
                                color: MilesColors.cream50, fontSize: 10.5),
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
                            color: MilesColors.gilt, fontSize: 11),
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
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
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
                          await _startReactionCapture(pos.x, pos.y);
                        },
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
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
                  if (!isMe)
                    ..._reactions.map((r) => _ReactionGifWidget(
                          reaction: r,
                          containerWidth: w,
                          containerHeight: h,
                          size: _reactionSize(r.x, r.y),
                          borderRadius: _reactionBorderRadius(r.y),
                          onExpired: () {
                            if (mounted) setState(() => _reactions.remove(r));
                          },
                        )),
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
                      ]),
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

/// Glowing neon "hot lines" that fade with age — connects consecutive points of
/// the same stroke; newer segments are brighter (a comet tail).
class _NeonPainter extends CustomPainter {
  _NeonPainter(this.points, this.now);
  final List<_NP> points;
  final int now;

  static const _life = 1300; // ms
  static const _neon = Color(0xFFFF4D8D);

  @override
  void paint(Canvas c, Size s) {
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      if (a.stroke != b.stroke) continue; // don't bridge separate strokes
      final age = now - b.t;
      if (age > _life) continue;
      final op = (1 - age / _life).clamp(0.0, 1.0);
      final p1 = Offset(a.x * s.width, a.y * s.height);
      final p2 = Offset(b.x * s.width, b.y * s.height);
      c.drawLine(
          p1,
          p2,
          Paint()
            ..color = _neon.withValues(alpha: 0.35 * op)
            ..strokeWidth = 14
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      c.drawLine(
          p1,
          p2,
          Paint()
            ..color =
                Color.lerp(_neon, Colors.white, 0.4)!.withValues(alpha: op)
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant _NeonPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reaction GIF widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ReactionGifWidget extends StatefulWidget {
  final _ActiveReactionGif reaction;
  final double containerWidth;
  final double containerHeight;
  final double size;
  final double borderRadius;
  final VoidCallback onExpired;

  const _ReactionGifWidget({
    required this.reaction,
    required this.containerWidth,
    required this.containerHeight,
    required this.size,
    required this.borderRadius,
    required this.onExpired,
  });

  @override
  State<_ReactionGifWidget> createState() => _ReactionGifWidgetState();
}

class _ReactionGifWidgetState extends State<_ReactionGifWidget>
    with TickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late AnimationController _pulseCtrl;
  VideoPlayerController? _vpc;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0,
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

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
        _pulseCtrl.stop();
        _fadeCtrl.reverse().then((_) {
          if (mounted) widget.onExpired();
        });
      }
    });
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _pulseCtrl.dispose();
    _vpc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sz = widget.size;
    final br = widget.borderRadius;
    final half = sz / 2;
    final pixelX = widget.reaction.x * widget.containerWidth;
    final pixelY = widget.reaction.y * widget.containerHeight;
    return Positioned(
      left: (pixelX - half).clamp(0.0, widget.containerWidth - sz),
      top: (pixelY - half).clamp(0.0, widget.containerHeight - sz),
      child: FadeTransition(
        opacity: _fadeCtrl,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.3, end: 1.0),
          duration: const Duration(milliseconds: 400),
          curve: Curves.elasticOut,
          builder: (_, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, child) {
              final pulseScale = 1.0 + _pulseCtrl.value * 0.18;
              final pulseOpacity = (1 - _pulseCtrl.value) * 0.6;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Breathing outer ring
                  Transform.scale(
                    scale: pulseScale,
                    child: Container(
                      width: sz,
                      height: sz,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(br),
                        border: Border.all(
                          color: MilesColors.ember
                              .withValues(alpha: pulseOpacity),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  child!,
                ],
              );
            },
            child: Container(
              width: sz,
              height: sz,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(br),
                border: Border.all(
                  color: MilesColors.ember.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: MilesColors.ember.withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(br > 900 ? br : br - 2),
                child: widget.reaction.isPhoto
                    ? Image.network(
                        widget.reaction.mediaUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const ColoredBox(
                          color: MilesColors.surface1,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: MilesColors.ember,
                          ),
                        ),
                      )
                    : (_videoReady && _vpc != null
                        ? FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: _vpc!.value.size.width,
                              height: _vpc!.value.size.height,
                              child: VideoPlayer(_vpc!),
                            ),
                          )
                        : const ColoredBox(
                            color: MilesColors.surface1,
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: MilesColors.ember,
                              ),
                            ),
                          )),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionCameraSheet extends StatefulWidget {
  const _ReactionCameraSheet({this.mode = _CameraMode.video});
  final _CameraMode mode;

  static Future<File?> showPhoto(BuildContext context) {
    return showModalBottomSheet<File?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ReactionCameraSheet(mode: _CameraMode.photo),
    );
  }

  static Future<File?> showVideo(BuildContext context) {
    return showModalBottomSheet<File?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ReactionCameraSheet(mode: _CameraMode.video),
    );
  }

  @override
  State<_ReactionCameraSheet> createState() => _ReactionCameraSheetState();
}

class _ReactionCameraSheetState extends State<_ReactionCameraSheet> {
  CameraController? _ctrl;
  List<CameraDescription> _cameras = [];
  int _camIndex = 1; // front camera default
  bool _recording = false;
  int _countdown = 5;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;
    _camIndex = _cameras.length > 1 ? 1 : 0;
    await _setup(_cameras[_camIndex]);
  }

  Future<void> _setup(CameraDescription cam) async {
    await _ctrl?.dispose();
    _ctrl = CameraController(
      cam,
      ResolutionPreset.low,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _ctrl!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _flip() async {
    if (_cameras.length < 2 || _recording) return;
    _camIndex = (_camIndex + 1) % _cameras.length;
    await _setup(_cameras[_camIndex]);
  }

  Future<void> _record() async {
    if (_ctrl == null || _recording) return;
    setState(() {
      _recording = true;
      _countdown = 5;
    });
    await _ctrl!.startVideoRecording();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        await _stop();
      }
    });
  }

  Future<void> _stop() async {
    if (!_recording) return;
    _timer?.cancel();
    final xfile = await _ctrl!.stopVideoRecording();
    setState(() => _recording = false);
    if (mounted) Navigator.of(context).pop(File(xfile.path));
  }

  Future<void> _snap() async {
    if (_ctrl == null) return;
    final xfile = await _ctrl!.takePicture();
    if (mounted) Navigator.of(context).pop(File(xfile.path));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      blur: MilesColors.blurLg,
      radius: 24,
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          children: [
            const SizedBox(height: 12),
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
            const SizedBox(height: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _ctrl?.value.isInitialized == true
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            Transform.scale(
                              scaleX: _camIndex == 1 ? -1 : 1,
                              child: CameraPreview(_ctrl!),
                            ),
                            if (_recording)
                              Center(
                                child: Text(
                                  '$_countdown',
                                  style: GoogleFonts.fraunces(
                                    fontSize: 80,
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            if (_recording)
                              Positioned(
                                top: 14,
                                left: 14,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 9,
                                      height: 9,
                                      decoration: const BoxDecoration(
                                        color: Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    const Text(
                                      'REC',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (!_recording && _cameras.length > 1)
                              Positioned(
                                top: 14,
                                right: 14,
                                child: GestureDetector(
                                  onTap: _flip,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Icon(
                                      Icons.flip_camera_android,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        )
                      : Container(
                          color: MilesColors.nightDeep,
                          child: const Center(
                            child: CircularProgressIndicator(
                                color: MilesColors.ember),
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (widget.mode == _CameraMode.photo)
              GestureDetector(
                onTap: _snap,
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
                  child: const Icon(
                    Icons.photo_camera_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              )
            else if (!_recording)
              GestureDetector(
                onTap: _record,
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
                  child: const Icon(
                    Icons.videocam_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              )
            else
              Text(
                'Recording... $_countdown',
                style: GoogleFonts.inter(
                  color: MilesColors.taupe,
                  fontSize: 14,
                ),
              ),
            const SizedBox(height: 16),
            if (widget.mode == _CameraMode.photo || !_recording)
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: MilesColors.taupe),
                ),
              ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

/// A simple, gender-neutral illustrated figure — the placeholder until a real
/// photo is added.
class _SilhouettePainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
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
