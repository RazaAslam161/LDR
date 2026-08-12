import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/covers/cover_theme.dart';

/// A wall of read-only device statistics.
///
/// Everything on screen is the handset's own live state, which makes it
/// self-verifying: there is no data to fake, nothing that can be wrong, and it
/// visibly changes while it is being watched. Eyes glaze in under a second and
/// there is nothing to tap into — no list, no detail screen, no content. Being
/// boring is the entire product promise of this category, so nobody wonders why
/// it is boring.
///
/// **The way in: hold the battery ring.** It is a chart, not a control: normal
/// use is read, scroll, maybe pull to refresh, and none of that involves
/// touching it. Explicitly NOT the "tap the build number seven times" pattern —
/// that is a famous Android easter egg, and a curious person is measurably
/// likely to actually try it, which makes it the worst possible gesture here.
class DeviceInfoCover extends StatefulWidget {
  const DeviceInfoCover({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<DeviceInfoCover> createState() => _DeviceInfoCoverState();
}

class _DeviceInfoCoverState extends State<DeviceInfoCover>
    with CoverGate<DeviceInfoCover> {
  static const _channel = MethodChannel('miles/device_stats');

  Map<String, Object?> _stats = const {};
  bool _loaded = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    // Slow enough to be free, fast enough that a number moves while someone is
    // looking at it — which is what stops the screen reading as a screenshot.
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) => _read());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  void onCoverUnlocked() => widget.onAuthenticated();

  /// Reads what the platform will give us. A handset that answers nothing still
  /// gets a full screen — the Dart-side facts below are enough on their own.
  Future<void> _read() async {
    Map<String, Object?> stats = const {};
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>('read')
          .timeout(const Duration(seconds: 2));
      stats = raw ?? const {};
    } catch (_) {
      // Not Android, or the platform refused. Fall through with what we have.
    }
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _loaded = true;
    });
  }

  /// The door — see the class doc for why this control and not another.
  void _onRingHold() {
    if (_loaded) runEntryGate();
  }

  int get _battery => (_stats['batteryPercent'] as int?) ?? -1;
  bool get _charging => (_stats['charging'] as bool?) ?? false;

  @override
  Widget build(BuildContext context) {
    final theme = coverTheme(
      primary: const Color(0xFF3730A3),
      surface: const Color(0xFFF6F6FA),
    );
    final media = MediaQuery.of(context);
    final display = View.of(context).display;
    final pixels = media.size * media.devicePixelRatio;

    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('Device Info')),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _read,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Center(
                  // The door. A chart with no tap handler and no ripple.
                  child: GestureDetector(
                    onLongPress: _onRingHold,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 150,
                      height: 150,
                      child: CustomPaint(
                        painter: _RingPainter(
                          fraction: _battery < 0 ? 0 : _battery / 100,
                          track: theme.colorScheme.surfaceContainerHighest,
                          fill: theme.colorScheme.primary,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _battery < 0 ? '—' : '$_battery%',
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w300,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              Text(
                                _charging ? 'Charging' : 'Battery',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _Section(
                  title: 'Storage',
                  bar: _fraction('storageFree', 'storageTotal'),
                  rows: [
                    ('Free', _bytes(_stats['storageFree'])),
                    ('Total', _bytes(_stats['storageTotal'])),
                  ],
                ),
                _Section(
                  title: 'Memory',
                  bar: _fraction('ramFree', 'ramTotal'),
                  rows: [
                    ('Available', _bytes(_stats['ramFree'])),
                    ('Total', _bytes(_stats['ramTotal'])),
                  ],
                ),
                _Section(
                  title: 'Display',
                  rows: [
                    ('Resolution',
                        '${pixels.width.round()} × ${pixels.height.round()}'),
                    ('Density', '${media.devicePixelRatio.toStringAsFixed(1)}x'),
                    ('Refresh rate',
                        '${display.refreshRate.toStringAsFixed(0)} Hz'),
                  ],
                ),
                _Section(
                  title: 'System',
                  rows: [
                    ('Model', _text(_stats['model'])),
                    ('Manufacturer', _text(_stats['manufacturer'])),
                    ('Android', _androidVersion()),
                    ('Build', _text(_stats['buildId'])),
                    ('CPU cores', '${Platform.numberOfProcessors}'),
                    ('Uptime', _uptime()),
                  ],
                ),
                _Section(
                  title: 'Network',
                  rows: [('Connection', _text(_stats['network']))],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Used fraction — what a bar in a storage panel actually shows.
  double? _fraction(String freeKey, String totalKey) {
    final free = (_stats[freeKey] as num?)?.toDouble();
    final total = (_stats[totalKey] as num?)?.toDouble();
    if (free == null || total == null || total <= 0) return null;
    return ((total - free) / total).clamp(0.0, 1.0);
  }

  String _androidVersion() {
    final release = _stats['androidRelease'];
    final sdk = _stats['sdkInt'];
    if (release == null) return Platform.operatingSystemVersion;
    return sdk == null ? '$release' : '$release (API $sdk)';
  }

  String _uptime() {
    final ms = (_stats['uptimeMs'] as num?)?.toInt();
    if (ms == null) return '—';
    final d = Duration(milliseconds: ms);
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours.remainder(24)}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    return '${d.inMinutes}m';
  }

  static String _text(Object? v) => v == null ? '—' : '$v';

  static String _bytes(Object? v) {
    final b = (v as num?)?.toDouble();
    if (b == null) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = b;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(i >= 2 ? 1 : 0)} ${units[i]}';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, this.bar});

  final String title;
  final List<(String, String)> rows;
  final double? bar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: scheme.primary,
            ),
          ),
          if (bar != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: bar,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
          const SizedBox(height: 4),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(row.$1,
                      style: TextStyle(color: scheme.onSurfaceVariant),),
                  Flexible(
                    child: Text(
                      row.$2,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    canvas
      ..drawCircle(centre, radius, stroke..color = track)
      ..drawArc(
        Rect.fromCircle(center: centre, radius: radius),
        -1.5707963267948966,
        6.283185307179586 * fraction,
        false,
        stroke..color = fill,
      );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction;
}
