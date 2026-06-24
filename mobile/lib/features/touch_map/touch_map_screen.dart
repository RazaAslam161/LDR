import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/features/touch_map/touch_map_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A named hit-zone on the silhouette (normalized 0–1 coordinates).
class _Zone {
  const _Zone(this.key, this.x, this.y);
  final String key;
  final double x;
  final double y;
}

const List<_Zone> _zones = [
  _Zone('head', 0.50, 0.09),
  _Zone('neck', 0.50, 0.155),
  _Zone('left_shoulder', 0.40, 0.21),
  _Zone('right_shoulder', 0.60, 0.21),
  _Zone('heart', 0.45, 0.28),
  _Zone('chest', 0.55, 0.28),
  _Zone('left_arm', 0.31, 0.35),
  _Zone('right_arm', 0.69, 0.35),
  _Zone('stomach', 0.50, 0.42),
  _Zone('left_hand', 0.25, 0.47),
  _Zone('right_hand', 0.75, 0.47),
  _Zone('left_hip', 0.44, 0.50),
  _Zone('right_hip', 0.56, 0.50),
  _Zone('left_thigh', 0.44, 0.64),
  _Zone('right_thigh', 0.56, 0.64),
  _Zone('left_knee', 0.44, 0.76),
  _Zone('right_knee', 0.56, 0.76),
  _Zone('left_foot', 0.43, 0.92),
  _Zone('right_foot', 0.57, 0.92),
];

class _TouchType {
  const _TouchType(this.key, this.emoji, this.label, this.color);
  final String key;
  final String emoji;
  final String label;
  final Color color;
}

const List<_TouchType> _types = [
  _TouchType('glow', '💫', 'Glow', MilesColors.blush),
  _TouchType('kiss', '💋', 'Kiss', Color(0xFFD45A77)),
  _TouchType('hug', '🤗', 'Hug', MilesColors.emberSoft),
];

_TouchType _typeOf(String key) =>
    _types.firstWhere((t) => t.key == key, orElse: () => _types.first);

class _ActiveTouch {
  _ActiveTouch(this.id, this.x, this.y, this.type);
  final int id;
  final double x;
  final double y;
  final String type;
}

/// Reach out and touch them, across the distance. Tap a spot on the silhouette
/// to send a glow; feel theirs land on you in real time.
class TouchMapScreen extends ConsumerStatefulWidget {
  const TouchMapScreen({super.key});

  @override
  ConsumerState<TouchMapScreen> createState() => _TouchMapScreenState();
}

class _TouchMapScreenState extends ConsumerState<TouchMapScreen> {
  String _type = 'glow';
  String? _coupleId;
  RealtimeChannel? _channel;
  final List<_ActiveTouch> _active = [];
  int _nextId = 0;

  String? _partnerPhotoUrl;
  bool _hasMyPhoto = false;
  bool _uploadingPhoto = false;
  Offset? _lastPan; // throttle caress sends

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure(); // intimate photos — block screenshots
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    _coupleId = couple.id;
    _channel = TouchMapRepository.subscribe(couple.id, _onIncoming);
    reportScreen(ref, 'Touch'); // partner sees we're in Touch
    _loadPhotos();
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    reportActiveTab(ref);
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadPhotos() async {
    final id = _coupleId;
    if (id == null) return;
    final partner = await PresenceService.fetchPartner(id);
    final mine = await PresenceService.fetchMine(id);
    final url = await TouchMapRepository.signedBodyUrl(partner?.bodyPhotoPath);
    if (mounted) {
      setState(() {
        _partnerPhotoUrl = url;
        _hasMyPhoto = mine?.bodyPhotoPath != null;
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
    if (path != null) await PresenceService.setBodyPhoto(id, path);
    if (mounted) {
      setState(() {
        _uploadingPhoto = false;
        _hasMyPhoto = path != null;
      });
    }
  }

  _Zone? _zoneByKey(String key) {
    for (final z in _zones) {
      if (z.key == key) return z;
    }
    return null;
  }

  void _onIncoming(BodyTouch t) {
    final uid = SupabaseService.currentUserId;
    if (t.isMine(uid) || !mounted) return; // mine already shown optimistically
    if (t.posX != null && t.posY != null) {
      _spawnAt(t.posX!, t.posY!, t.type);
    } else {
      final z = _zoneByKey(t.zone);
      if (z == null) return;
      _spawnAt(z.x, z.y, t.type);
    }
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 200), HapticFeedback.lightImpact);
  }

  void _tap(_Zone z) {
    HapticFeedback.lightImpact();
    _spawnAt(z.x, z.y, _type);
    final id = _coupleId;
    if (id != null) {
      TouchMapRepository.sendTouch(coupleId: id, zone: z.key, type: _type);
    }
  }

  /// Photo-mode touch at a normalized (x,y) anywhere on the partner's photo.
  void _touchAt(double x, double y) {
    HapticFeedback.lightImpact();
    _spawnAt(x, y, _type);
    final id = _coupleId;
    if (id != null) {
      TouchMapRepository.sendTouch(
          coupleId: id, zone: 'free', type: _type, posX: x, posY: y);
    }
  }

  void _spawnAt(double x, double y, String type) {
    setState(() => _active.add(_ActiveTouch(_nextId++, x, y, type)));
  }

  void _remove(int id) {
    if (!mounted) return;
    setState(() => _active.removeWhere((t) => t.id == id));
  }

  @override
  Widget build(BuildContext context) {
    final linked = _coupleId != null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Touch'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
          ),
        ),
        actions: [
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
      body: !linked
          ? const Center(
              child: Text('Link with your partner first.',
                  style: TextStyle(color: MilesColors.taupe)))
          : Column(
              children: [
                const SizedBox(height: 8),
                Text(
                  _partnerPhotoUrl != null
                      ? 'Touch anywhere on them — they feel it in real time.'
                      : 'Tap a spot to send it. Feel theirs land on you.',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: MilesColors.taupe, fontSize: 12.5),
                ),
                if (!_hasMyPhoto)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Tap 📷 to add your photo so they can touch you too.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: MilesColors.gilt, fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 12),
                // Touch type selector
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final t in _types)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: GestureDetector(
                          onTap: () => setState(() => _type = t.key),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: t.color.withValues(
                                  alpha: _type == t.key ? 0.3 : 0.1),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: t.color.withValues(
                                      alpha: _type == t.key ? 0.8 : 0.3)),
                            ),
                            child: Text('${t.emoji} ${t.label}',
                                style: const TextStyle(
                                    color: MilesColors.cream50, fontSize: 13)),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final w = c.maxWidth, h = c.maxHeight;
                      // Photo mode — caress anywhere on the partner's photo.
                      if (_partnerPhotoUrl != null) {
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => _touchAt(
                              (d.localPosition.dx / w).clamp(0.0, 1.0),
                              (d.localPosition.dy / h).clamp(0.0, 1.0)),
                          onPanUpdate: (d) {
                            final x = (d.localPosition.dx / w).clamp(0.0, 1.0);
                            final y = (d.localPosition.dy / h).clamp(0.0, 1.0);
                            if (_lastPan == null ||
                                (Offset(x, y) - _lastPan!).distance > 0.05) {
                              _lastPan = Offset(x, y);
                              _touchAt(x, y);
                            }
                          },
                          onPanEnd: (_) => _lastPan = null,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.network(
                                _partnerPhotoUrl!,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Center(
                                  child: Text('Could not load their photo',
                                      style: TextStyle(color: MilesColors.taupe)),
                                ),
                              ),
                              for (final t in _active)
                                Positioned(
                                  key: ValueKey(t.id),
                                  left: t.x * w - 45,
                                  top: t.y * h - 45,
                                  child: _Glow(
                                      type: t.type,
                                      onDone: () => _remove(t.id)),
                                ),
                            ],
                          ),
                        );
                      }
                      // Silhouette fallback (no photos yet).
                      return Stack(
                        children: [
                          CustomPaint(
                            size: Size(w, h),
                            painter: _SilhouettePainter(),
                          ),
                          // Invisible tap zones
                          for (final z in _zones)
                            Positioned(
                              left: z.x * w - 26,
                              top: z.y * h - 26,
                              child: GestureDetector(
                                onTap: () => _tap(z),
                                behavior: HitTestBehavior.opaque,
                                child: const SizedBox(width: 52, height: 52),
                              ),
                            ),
                          // Active glows
                          for (final t in _active)
                            Positioned(
                              key: ValueKey(t.id),
                              left: t.x * w - 45,
                              top: t.y * h - 45,
                              child: _Glow(
                                type: t.type,
                                onDone: () => _remove(t.id),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// One animated touch: a soft radial glow (kiss adds a rising emoji).
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
                      child: Text(t.emoji,
                          style: TextStyle(fontSize: 18 + v * 8)),
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

/// A simple, gender-neutral illustrated figure (never a photo).
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

    // Limbs (under the torso).
    c
      ..drawLine(Offset(w * 0.40, h * 0.23), Offset(w * 0.25, h * 0.47), limb)
      ..drawLine(Offset(w * 0.60, h * 0.23), Offset(w * 0.75, h * 0.47), limb)
      ..drawLine(Offset(w * 0.46, h * 0.50), Offset(w * 0.43, h * 0.92), limb)
      ..drawLine(Offset(w * 0.54, h * 0.50), Offset(w * 0.57, h * 0.92), limb);

    // Neck.
    c.drawLine(
      Offset(w * 0.5, h * 0.135),
      Offset(w * 0.5, h * 0.19),
      Paint()
        ..color = fill.color
        ..strokeWidth = w * 0.055
        ..strokeCap = StrokeCap.round,
    );

    // Torso.
    final torso = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.37, h * 0.18, w * 0.26, h * 0.34),
      Radius.circular(w * 0.11),
    );
    c..drawRRect(torso, fill)..drawRRect(torso, stroke);

    // Head.
    final head = Offset(w * 0.5, h * 0.09);
    c..drawCircle(head, w * 0.07, fill)..drawCircle(head, w * 0.07, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
