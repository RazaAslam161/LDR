import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/features/disguise/covers/cover_theme.dart';

/// A stopwatch and a countdown timer.
///
/// The category with the least to find: a timer has no content at all, not even
/// an empty list, and a second one alongside the phone's own clock is
/// unremarkable because everybody has picked one up for a kitchen or a workout.
///
/// It is also the one disguise where a notification is completely natural,
/// which repairs the weakness in the others — a "Calculator" that posts "Tap to
/// open" is itself a tell, whereas a timer that goes off is the entire point of
/// a timer.
///
/// No door of its own. The way in is the move the owner recorded, matched by
/// the host's pointer layer over this screen; nothing here knows it exists.
class TimerCover extends StatefulWidget {
  const TimerCover({super.key});

  @override
  State<TimerCover> createState() => _TimerCoverState();
}

class _TimerCoverState extends State<TimerCover>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  // ── Stopwatch ──────────────────────────────────────────────────────────────
  final _watch = Stopwatch();
  final List<Duration> _laps = [];
  Timer? _tick;

  // ── Countdown ──────────────────────────────────────────────────────────────
  Duration _selected = const Duration(minutes: 5);
  Duration _remaining = const Duration(minutes: 5);
  DateTime? _deadline;
  Timer? _countTick;

  @override
  void dispose() {
    _tick?.cancel();
    _countTick?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  // ── Stopwatch behaviour ────────────────────────────────────────────────────

  /// 30ms, not 10: the display carries hundredths, but repainting at the rate
  /// the digits change would burn a frame budget on the cheap handsets this has
  /// to stay smooth on, and nobody can read the difference.
  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  void _toggleWatch() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_watch.isRunning) {
        _watch.stop();
        _tick?.cancel();
      } else {
        _watch.start();
        _startTicking();
      }
    });
  }

  void _lapOrReset() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_watch.isRunning) {
        _laps.insert(0, _watch.elapsed);
      } else {
        _watch.reset();
        _laps.clear();
      }
    });
  }

  // ── Countdown behaviour ────────────────────────────────────────────────────

  void _setPreset(Duration d) {
    if (_deadline != null) return;
    setState(() {
      _selected = d;
      _remaining = d;
    });
  }

  void _toggleCountdown() {
    HapticFeedback.selectionClick();
    if (_deadline != null) {
      _countTick?.cancel();
      setState(() => _deadline = null);
      return;
    }
    if (_remaining <= Duration.zero) return;
    setState(() => _deadline = DateTime.now().add(_remaining));
    _countTick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final end = _deadline;
      if (end == null || !mounted) return;
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) {
        _countTick?.cancel();
        setState(() {
          _deadline = null;
          _remaining = Duration.zero;
        });
        unawaited(_ring());
      } else {
        setState(() => _remaining = left);
      }
    });
  }

  void _resetCountdown() {
    _countTick?.cancel();
    setState(() {
      _deadline = null;
      _remaining = _selected;
    });
  }

  /// A real notification, on a channel created only by this cover.
  ///
  /// Nothing here can fail loudly: a countdown that throws on a handset with an
  /// unusual notification policy must still leave a working stopwatch behind
  /// it, because the cover failing visibly is the disguise failing.
  Future<void> _ring() async {
    HapticFeedback.heavyImpact();
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notif_timer'),
        ),
      );
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(buildTimerChannel());
      await plugin.show(
        id: 0x71DE,
        title: 'Timer finished',
        body: _label(_selected),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            kTimerChannelId,
            kTimerChannelName,
            channelDescription: kTimerChannelDesc,
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_notif_timer',
          ),
        ),
      );
    } catch (_) {
      // No notification permission, or no platform channel at all.
    }
  }

  // ── Rendering ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = coverTheme(
      primary: const Color(0xFF2E7D32),
      surface: const Color(0xFFF6F8F6),
    );
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Timer'),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [Tab(text: 'Timer'), Tab(text: 'Stopwatch')],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            controller: _tabs,
            children: [_buildCountdown(), _buildStopwatch()],
          ),
        ),
      ),
    );
  }

  Widget _buildCountdown() {
    final running = _deadline != null;
    return Column(
      children: [
        const Spacer(),
        Text(
          _clock(_remaining),
          style: const TextStyle(
            fontSize: 62,
            fontWeight: FontWeight.w200,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          children: [
            for (final m in const [1, 3, 5, 10, 30])
              ChoiceChip(
                label: Text('$m min'),
                selected: !running && _selected.inMinutes == m,
                onSelected:
                    running ? null : (_) => _setPreset(Duration(minutes: m)),
              ),
          ],
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: _resetCountdown,
                child: const Text('Reset'),
              ),
              const SizedBox(width: 16),
              FilledButton(
                onPressed: _toggleCountdown,
                child: Text(running ? 'Pause' : 'Start'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStopwatch() {
    final running = _watch.isRunning;
    return Column(
      children: [
        const SizedBox(height: 32),
        Text(
          _stopwatchText(_watch.elapsed),
          style: const TextStyle(
            fontSize: 56,
            fontWeight: FontWeight.w200,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton(
              onPressed: _lapOrReset,
              child: Text(running ? 'Lap' : 'Reset'),
            ),
            const SizedBox(width: 16),
            FilledButton(
              onPressed: _toggleWatch,
              child: Text(running ? 'Stop' : 'Start'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(),
        Expanded(
          child: ListView.separated(
            itemCount: _laps.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final number = _laps.length - i;
              final previous =
                  i + 1 < _laps.length ? _laps[i + 1] : Duration.zero;
              return ListTile(
                dense: true,
                leading: Text('Lap $number'),
                trailing: Text(
                  _stopwatchText(_laps[i] - previous),
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _stopwatchText(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final cs = (d.inMilliseconds.remainder(1000) ~/ 10).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s.$cs' : '$m:$s.$cs';
  }

  static String _clock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  static String _label(Duration d) =>
      d.inMinutes == 1 ? '1 minute' : '${d.inMinutes} minutes';
}
