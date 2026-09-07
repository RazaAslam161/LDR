import 'package:flutter/material.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A single point on a stroke. Normalised to 0..1 so it renders correctly
/// on partners' screens of any size.
class _TracePoint {
  const _TracePoint(this.dx, this.dy, this.t);
  factory _TracePoint.fromJson(Map<String, dynamic> j) => _TracePoint(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        (j['t'] as num).toInt(),
      );
  final double dx;
  final double dy;
  final int t; // ms since stroke start

  Map<String, dynamic> toJson() => {'x': dx, 'y': dy, 't': t};
}

/// A stroke = a list of points + the color the drawer picked.
class _TraceStroke {
  _TraceStroke({required this.color, required this.points});
  final Color color;
  final List<_TracePoint> points;

  /// The stroke's IDENTITY only — never its points.
  ///
  /// The wire used to carry the whole accumulated point list on every one of
  /// the ~30 sends a second, so one continuous drag cost O(N^2) bytes and the
  /// receiver rebuilt a fresh stroke each time. Points now travel as a batch
  /// beside this, keyed by sender + the canvas's per-stroke sequence number.
  Map<String, dynamic> headerJson(String from, int id) => {
        'from': from,
        'stroke': id,
        'r': (color.r * 255.0).round().clamp(0, 255),
        'g': (color.g * 255.0).round().clamp(0, 255),
        'b': (color.b * 255.0).round().clamp(0, 255),
      };
}

/// Public widget — wraps the whole Touch Trace experience.
class TouchTraceCanvas extends StatefulWidget {
  const TouchTraceCanvas({
    required this.coupleId,
    required this.userId,
    required this.partnerId,
    super.key,
  });

  final String coupleId;
  final String userId;
  final String partnerId;

  @override
  State<TouchTraceCanvas> createState() => _TouchTraceCanvasState();
}

class _TouchTraceCanvasState extends State<TouchTraceCanvas> {
  ManagedSubscription? _sub;
  final List<_TraceStroke> _strokes = [];

  /// Partner strokes still being drawn, keyed '<sender>:<stroke id>'. Identity
  /// on the wire, so two people holding the same colour stay two strokes.
  final Map<String, _TraceStroke> _incoming = {};

  /// Bumped per stroke this device draws; travels with every point batch.
  int _strokeSeq = 0;
  _TraceStroke? _activeStroke;
  DateTime? _strokeStart;

  final _colors = const [
    Color(0xFFEF6F58), // coral
    Color(0xFFF4937E),
    Color(0xFFFBF8F4), // cream
    Color(0xFF34D399), // emerald
    Color(0xFFA78BFA), // violet
    Color(0xFFFBBF24), // amber
  ];
  int _colorIdx = 0;

  @override
  void initState() {
    super.initState();
    // ManagedSubscription, not a hand-rolled realtimeResumed listener: this
    // screen used to call the old channel's unsubscribe() without awaiting it
    // and build a channel on the identical topic in the same breath, which is
    // the app-wide subscription-health bug named in realtime_service.dart —
    // and it subscribed with no status callback, so a rejoin that never landed
    // was silent. Touch Trace has no table behind the broadcast: the partner's
    // strokes simply stop while this canvas keeps drawing, which reads as "she
    // isn't there" rather than as a failure.
    _sub = ManagedSubscription.start(_build);
  }

  RealtimeChannel _build() {
    final ch = SupabaseService.client.channel('touch_trace:${widget.coupleId}', opts: const RealtimeChannelConfig(private: true));

    // Receive partner's strokes
    ch.onBroadcast(
      event: 'stroke_point',
      callback: (payload) {
        final from = payload['from'] as String?;
        if (from == widget.userId) return; // ignore our own echoes

        // BOTH WIRE SHAPES, because the partner's handset updates separately.
        //
        //   legacy (build <= 76): {'stroke': {r,g,b,points:[...]}, 'point': {}}
        //   current            : {'stroke': <int id>, r, g, b, 'points': [...]}
        //
        // A build that only knows the legacy shape cannot read the current one
        // — which is a coordinated-update requirement the owner has to know
        // about, recorded in BRAIN — but this side costs nothing and means a
        // NEW phone never goes blank against an OLD one.
        final rawStroke = payload['stroke'];
        final legacy = rawStroke is Map<String, dynamic>;
        final colorSrc = legacy ? rawStroke : payload;
        // Legacy identity is the colour it always was; there is no id in it.
        final id = legacy ? 'legacy' : '$rawStroke';
        final pointsJson = <Map<String, dynamic>>[
          if (payload['points'] case final List<dynamic> l)
            for (final p in l)
              if (p is Map<String, dynamic>) p,
          if (payload['point'] case final Map<String, dynamic> p) p,
        ];
        if (pointsJson.isEmpty) return;

        setState(() {
          // Keyed by SENDER + stroke id, never by colour. Both phones start on
          // _colors[0], so "the last stroke is a different colour from mine"
          // was false on every broadcast: each one appended a whole new stroke
          // carrying the partner's entire point history, and the same line was
          // overdrawn hundreds of times at O(N^2) cost until the canvas locked
          // up. Two people picking the same colour on purpose did it too.
          final key = '$from:$id';
          var stroke = _incoming[key];
          if (stroke == null) {
            stroke = _TraceStroke(
              color: Color.fromARGB(
                255,
                (colorSrc['r'] as num).toInt(),
                (colorSrc['g'] as num).toInt(),
                (colorSrc['b'] as num).toInt(),
              ),
              points: [],
            );
            _incoming[key] = stroke;
            _strokes.add(stroke);
          }
          for (final p in pointsJson) {
            stroke.points.add(_TracePoint.fromJson(p));
          }
        });
      },
    );

    ch.onBroadcast(
      event: 'stroke_end',
      callback: (payload) {
        final from = payload['from'] as String?;
        if (from == widget.userId) return;
        // Already rendered incrementally. The entry is dropped so the map does
        // not grow for the life of the session — the stroke itself stays in
        // _strokes and keeps painting.
        _incoming.remove('$from:${payload['stroke']}');
      },
    );

    ch.onBroadcast(
      event: 'clear',
      callback: (payload) {
        final from = payload['from'] as String?;
        if (from == widget.userId) return;
        setState(() {
          _strokes.clear();
          _incoming.clear();
        });
      },
    );

    return ch.subscribe();
  }

  @override
  void dispose() {
    _sub?.dispose();
    super.dispose();
  }

  Color _myColor() => _colors[_colorIdx];

  void _onPanStart(DragStartDetails _) {
    _strokeStart = DateTime.now();
    _strokeSeq++;
    _pending.clear();
    _activeStroke = _TraceStroke(color: _myColor(), points: []);
    setState(() => _strokes.add(_activeStroke!));
  }

  void _onPanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_activeStroke == null || _strokeStart == null) return;
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    final dx = (details.localPosition.dx / size.width).clamp(0.0, 1.0);
    final dy = (details.localPosition.dy / size.height).clamp(0.0, 1.0);
    final t = DateTime.now().difference(_strokeStart!).inMilliseconds;

    final point = _TracePoint(dx, dy, t);
    setState(() => _activeStroke!.points.add(point));

    // Stream to partner in real time (throttled to ~30fps).
    _throttledSend(_activeStroke!, point);
  }

  void _onPanEnd(DragEndDetails _) {
    // Flushed before the end marker, or the tail of every stroke — up to a
    // whole throttle window of points — never reaches the partner at all.
    if (_activeStroke != null) _flushPending(_activeStroke!);
    _sub?.channel?.sendBroadcastMessage(
      event: 'stroke_end',
      payload: {'from': widget.userId, 'stroke': _strokeSeq},
    );
    _activeStroke = null;
    _strokeStart = null;
  }

  // ─── Throttled broadcast (~every 33ms) ────────────────────────────────────
  DateTime? _lastSend;

  /// Points drawn since the last flush.
  ///
  /// The throttle used to DROP everything inside its 33 ms window and send the
  /// whole stroke again, so the rate was capped by discarding points and the
  /// size was uncapped by resending history — the partner's copy was the
  /// decimated one and the wire carried the rest. It batches now: every point
  /// is sent exactly once, ~30 times a second.
  final List<_TracePoint> _pending = [];

  void _throttledSend(_TraceStroke stroke, _TracePoint point) {
    _pending.add(point);
    final now = DateTime.now();
    if (_lastSend != null && now.difference(_lastSend!).inMilliseconds < 33) {
      return;
    }
    _flushPending(stroke);
  }

  void _flushPending(_TraceStroke stroke) {
    if (_pending.isEmpty) return;
    _lastSend = DateTime.now();
    _sub?.channel?.sendBroadcastMessage(
      event: 'stroke_point',
      payload: {
        ...stroke.headerJson(widget.userId, _strokeSeq),
        'points': [for (final p in _pending) p.toJson()],
      },
    );
    _pending.clear();
  }

  void _clearAll() {
    setState(() {
      _strokes.clear();
      _incoming.clear();
    });
    _sub?.channel?.sendBroadcastMessage(
      event: 'clear',
      payload: {'from': widget.userId},
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            // Drawing layer
            GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: (d) => _onPanUpdate(d, constraints),
              onPanEnd: _onPanEnd,
              child: CustomPaint(
                size: Size.infinite,
                painter: _TracePainter(_strokes, _myColor()),
              ),
            ),

            // Color picker + clear (top)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < _colors.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => setState(() => _colorIdx = i),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: _colors[i],
                                shape: BoxShape.circle,
                                border: _colorIdx == i
                                    ? Border.all(
                                        color: const Color(0xFFFBF8F4),
                                        width: 2,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  IconButton(
                    onPressed: _clearAll,
                    icon: const Icon(
                      Icons.refresh,
                      color: Color(0x80F5EFE6),
                      size: 20,
                    ),
                    tooltip: 'Clear',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Paints all strokes (mine + partner's) into a single warm-glow canvas.
class _TracePainter extends CustomPainter {
  _TracePainter(this.strokes, this.myColor);
  final List<_TraceStroke> strokes;
  final Color myColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Soft dark background — the glow reads better on this than pure black.
    final bg = Paint()
      ..color = const Color(0xFF0B0F16)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, bg);

    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final isMine = stroke.color.toARGB32() == myColor.toARGB32();

      // Glow pass — wider, semi-transparent.
      final glow = Paint()
        ..color = stroke.color.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = isMine ? 18 : 22
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      _drawPath(canvas, size, stroke.points, glow);

      // Core line — bright, thinner.
      final core = Paint()
        ..color = stroke.color.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = isMine ? 4 : 5;
      _drawPath(canvas, size, stroke.points, core);
    }
  }

  void _drawPath(
    Canvas canvas,
    Size size,
    List<_TracePoint> points,
    Paint paint,
  ) {
    if (points.length == 1) {
      // Dot when only one point so far
      final p = points.first;
      canvas.drawCircle(
        Offset(p.dx * size.width, p.dy * size.height),
        paint.strokeWidth / 2,
        paint,
      );
      return;
    }
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final offset = Offset(p.dx * size.width, p.dy * size.height);
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TracePainter old) => true;
}
