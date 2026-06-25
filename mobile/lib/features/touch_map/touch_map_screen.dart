import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/touch_map/touch_map_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  RealtimeChannel? _channel;
  final List<_ActiveTouch> _active = [];
  int _nextId = 0;

  String? _myPhotoUrl;
  String? _partnerPhotoUrl;
  bool _uploadingPhoto = false;
  Offset? _lastPan; // throttle caress sends
  double _heat = 0; // shared warmth 0..1
  Timer? _heatTimer;

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
    // Ephemeral, low-latency touch sync (no DB writes).
    _channel = SupabaseService.client
        .channel('touch:${couple.id}')
        .onBroadcast(event: 'touch', callback: _onTouchMsg)
        .subscribe();
    reportScreen(ref, 'Touch');
    _loadPhotos();
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    _heatTimer?.cancel();
    reportActiveTab(ref);
    _channel?.unsubscribe();
    super.dispose();
  }

  void _haptic(String type) {
    switch (type) {
      case 'kiss':
        HapticFeedback.mediumImpact();
      case 'hug':
        HapticFeedback.heavyImpact();
        Future.delayed(
            const Duration(milliseconds: 140), HapticFeedback.heavyImpact);
      default:
        HapticFeedback.lightImpact();
    }
  }

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
      if (mounted) setState(() => _myPhotoUrl = url);
    }
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  /// Local touch on [owner]'s body at normalized (x,y): show it here, buzz a
  /// light feedback, and broadcast so it lands on their phone too.
  void _touch(String owner, double x, double y) {
    HapticFeedback.selectionClick(); // light feedback for the toucher
    _bumpHeat();
    _spawn(owner, x, y, _type);
    _channel?.sendBroadcastMessage(event: 'touch', payload: {
      'from': _myUid,
      'target': owner,
      'x': x,
      'y': y,
      'type': _type,
    });
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
              ],
            ),
    );
  }

  Widget _typeSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final t in _types)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: GestureDetector(
              onTap: () => setState(() => _type = t.key),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: t.color.withValues(alpha: _type == t.key ? 0.3 : 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: t.color
                          .withValues(alpha: _type == t.key ? 0.8 : 0.3)),
                ),
                child: Text('${t.emoji} ${t.label}',
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 13)),
              ),
            ),
          ),
      ],
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
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _touch(
                  owner,
                  (d.localPosition.dx / w).clamp(0.0, 1.0),
                  (d.localPosition.dy / h).clamp(0.0, 1.0)),
              onPanUpdate: (d) {
                final x = (d.localPosition.dx / w).clamp(0.0, 1.0);
                final y = (d.localPosition.dy / h).clamp(0.0, 1.0);
                if (_lastPan == null ||
                    (Offset(x, y) - _lastPan!).distance > 0.05) {
                  _lastPan = Offset(x, y);
                  _touch(owner, x, y);
                }
              },
              onPanEnd: (_) => _lastPan = null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (photoUrl != null)
                    Image.network(photoUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            CustomPaint(painter: _SilhouettePainter()))
                  else
                    CustomPaint(painter: _SilhouettePainter()),
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
    c..drawRRect(torso, fill)..drawRRect(torso, stroke);

    final head = Offset(w * 0.5, h * 0.09);
    c..drawCircle(head, w * 0.07, fill)..drawCircle(head, w * 0.07, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
