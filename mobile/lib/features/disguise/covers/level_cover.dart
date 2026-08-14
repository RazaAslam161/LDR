import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/covers/cover_theme.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// A bubble level and a compass.
///
/// The strongest anti-screenshot cover in the set. Every other disguise can be
/// mistaken for a still image if nobody touches it; this one moves the instant
/// the phone does, with no data to fabricate and nothing that can be wrong,
/// because the numbers are the device's own sensors. It is also a tool people
/// use for ten seconds and never think about again — no content, no history,
/// nothing that could belong to a person.
///
/// **The way in: hold the angle readout with the phone lying flat**, within
/// half a degree on both axes. Two conditions, and they fight each other with
/// ordinary use: levelling something means holding the phone edge-on against
/// it, hands on the frame, eyes on the bubble. Flat on a table with a finger
/// held on a passive number is precisely the moment a real user has stopped
/// using it.
class LevelCover extends StatefulWidget {
  const LevelCover({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<LevelCover> createState() => _LevelCoverState();
}

class _LevelCoverState extends State<LevelCover>
    with CoverGate<LevelCover>, SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  StreamSubscription<AccelerometerEvent>? _accel;
  StreamSubscription<MagnetometerEvent>? _mag;

  double _pitch = 0;
  double _roll = 0;
  double _heading = 0;
  bool _hasCompass = true;

  @override
  void initState() {
    super.initState();
    _accel = accelerometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen(_onAccelerometer, onError: (_) {});
    _mag = magnetometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen(_onMagnetometer, onError: (_) => _noCompass());
  }

  @override
  void dispose() {
    _accel?.cancel();
    _mag?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  @override
  void onCoverUnlocked() => widget.onAuthenticated();

  void _noCompass() {
    if (mounted && _hasCompass) setState(() => _hasCompass = false);
  }

  /// Raw accelerometer output is noisy enough that an untouched phone reads
  /// ±0.3° of jitter, which would make the bubble twitch and — worse for the
  /// entry gate — flicker in and out of "flat". A low-pass filter is what every
  /// real level does about it.
  void _onAccelerometer(AccelerometerEvent e) {
    const smoothing = 0.15;
    final pitch = math.atan2(e.y, math.sqrt(e.x * e.x + e.z * e.z)) * 180 / math.pi;
    final roll = math.atan2(e.x, math.sqrt(e.y * e.y + e.z * e.z)) * 180 / math.pi;
    if (!mounted) return;
    setState(() {
      _pitch += (pitch - _pitch) * smoothing;
      _roll += (roll - _roll) * smoothing;
    });
  }

  void _onMagnetometer(MagnetometerEvent e) {
    if (!mounted) return;
    final raw = (math.atan2(-e.x, e.y) * 180 / math.pi + 360) % 360;
    setState(() {
      // Shortest-way interpolation, so the needle does not spin the long way
      // round every time the heading crosses north.
      var delta = raw - _heading;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;
      _heading = (_heading + delta * 0.2 + 360) % 360;
    });
  }

  bool get _isFlat => _pitch.abs() <= 0.5 && _roll.abs() <= 0.5;

  /// The door — see the class doc for why this state and not another.
  void _onReadoutHold() {
    if (_isFlat) runEntryGate();
  }

  @override
  Widget build(BuildContext context) {
    final theme = coverTheme(
      primary: const Color(0xFFB06A12),
      surface: const Color(0xFFF6F1E7),
    );
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Level'),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [Tab(text: 'Level'), Tab(text: 'Compass')],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            controller: _tabs,
            children: [_buildLevel(theme), _buildCompass(theme)],
          ),
        ),
      ),
    );
  }

  Widget _buildLevel(ThemeData theme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 260,
          height: 260,
          child: CustomPaint(
            painter: _VialPainter(
              pitch: _pitch,
              roll: _roll,
              level: _isFlat,
              frame: theme.colorScheme.primary,
              face: theme.colorScheme.surfaceContainerLowest,
              bubble: const Color(0xFF2E7D57),
            ),
          ),
        ),
        const SizedBox(height: 28),
        // The door. A passive readout: no ripple, no tap handler, nothing that
        // says it can be pressed.
        GestureDetector(
          onLongPress: _onReadoutHold,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              '${_pitch.abs().toStringAsFixed(1)}°  ·  '
              '${_roll.abs().toStringAsFixed(1)}°',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w200,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
        Text(
          _isFlat ? 'Level' : 'Pitch · Roll',
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 1.2,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildCompass(ThemeData theme) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 260,
          height: 260,
          child: CustomPaint(
            painter: _CompassPainter(
              heading: _heading,
              frame: theme.colorScheme.primary,
              face: theme.colorScheme.surfaceContainerLowest,
              ink: theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '${_heading.round()}°  ${_cardinal(_heading)}',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w300,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _hasCompass
              ? 'Move the phone in a figure 8 to calibrate'
              : 'No compass on this device',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  static String _cardinal(double deg) {
    const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return points[(((deg + 22.5) % 360) ~/ 45)];
  }
}

class _VialPainter extends CustomPainter {
  const _VialPainter({
    required this.pitch,
    required this.roll,
    required this.level,
    required this.frame,
    required this.face,
    required this.bubble,
  });

  final double pitch;
  final double roll;
  final bool level;
  final Color frame;
  final Color face;
  final Color bubble;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;

    canvas.drawCircle(centre, radius, Paint()..color = face);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = frame,
    );

    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = frame.withValues(alpha: 0.35);
    canvas.drawLine(Offset(centre.dx - radius, centre.dy),
        Offset(centre.dx + radius, centre.dy), hair,);
    canvas.drawLine(Offset(centre.dx, centre.dy - radius),
        Offset(centre.dx, centre.dy + radius), hair,);
    for (final r in [radius / 3, radius * 2 / 3]) {
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = frame.withValues(alpha: 0.25),
      );
    }

    // The target the bubble has to land in, sized to the same half-degree the
    // entry gate uses — so "inside the ring" and "flat" are the same thing to
    // the eye and to the code.
    const bubbleR = 20.0;
    canvas.drawCircle(
      centre,
      bubbleR + 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = level ? bubble : frame.withValues(alpha: 0.45),
    );

    // 30° of tilt runs the bubble to the rim, which is the range a phone-sized
    // level is useful over.
    final travel = radius - bubbleR - 6;
    final dx = (roll / 30).clamp(-1.0, 1.0) * travel;
    final dy = (pitch / 30).clamp(-1.0, 1.0) * travel;
    canvas.drawCircle(centre + Offset(dx, dy), bubbleR,
        Paint()..color = level ? bubble : bubble.withValues(alpha: 0.75),);
  }

  @override
  bool shouldRepaint(_VialPainter old) =>
      old.pitch != pitch || old.roll != roll || old.level != level;
}

class _CompassPainter extends CustomPainter {
  const _CompassPainter({
    required this.heading,
    required this.frame,
    required this.face,
    required this.ink,
  });

  final double heading;
  final Color frame;
  final Color face;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;

    canvas.drawCircle(centre, radius, Paint()..color = face);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = frame,
    );

    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..rotate(-heading * math.pi / 180);

    final tick = Paint()..color = ink.withValues(alpha: 0.5);
    for (var d = 0; d < 360; d += 15) {
      final major = d % 45 == 0;
      final a = d * math.pi / 180;
      final outer = radius - 6;
      final inner = outer - (major ? 14 : 7);
      canvas.drawLine(
        Offset(math.sin(a) * inner, -math.cos(a) * inner),
        Offset(math.sin(a) * outer, -math.cos(a) * outer),
        tick..strokeWidth = major ? 2 : 1,
      );
    }
    const labels = {0: 'N', 90: 'E', 180: 'S', 270: 'W'};
    labels.forEach((deg, text) {
      final a = deg * math.pi / 180;
      final r = radius - 38;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: deg == 0 ? const Color(0xFFB3261E) : ink,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(math.sin(a) * r - painter.width / 2,
            -math.cos(a) * r - painter.height / 2,),
      );
    });
    canvas.restore();

    // The fixed pointer: it marks where the phone is aimed, so it must NOT
    // rotate with the dial.
    final needle = Path()
      ..moveTo(centre.dx, centre.dy - radius + 2)
      ..lineTo(centre.dx - 9, centre.dy - radius + 22)
      ..lineTo(centre.dx + 9, centre.dy - radius + 22)
      ..close();
    canvas.drawPath(needle, Paint()..color = const Color(0xFFB3261E));
  }

  @override
  bool shouldRepaint(_CompassPainter old) => old.heading != heading;
}
