import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A local forecast panel.
///
/// The numbers are generated, not fetched — deliberately. A weather cover that
/// calls a weather API would put an unexplained third-party request in the
/// network log of an app that is meant to look like a weather app to a person,
/// not to a packet capture. What matters is that it is internally consistent and
/// stable: seeded from the day, so it does not reshuffle every time it opens,
/// which is what a fake would do.
///
/// No door of its own. The way in is the move the owner recorded, matched by
/// the host's pointer layer over this screen; nothing here knows it exists.
class WeatherCover extends StatefulWidget {
  const WeatherCover({super.key});

  @override
  State<WeatherCover> createState() => _WeatherCoverState();
}

class _WeatherCoverState extends State<WeatherCover> {
  late final _Forecast _forecast = _Forecast.forToday();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF4285F4), Color(0xFF77A7F7), Color(0xFFBBD3FB)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Clearance the deleted exit button used to occupy — without it
              // the location line sits against the status bar, which is a
              // louder tell than the button was.
              const SizedBox(height: 24),
              const Text(
                'Current location',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                _dayLabel(now),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 24),
              Icon(_forecast.today.icon,
                  size: 84, color: Colors.white.withValues(alpha: 0.95),),
              const SizedBox(height: 8),
              Text(
                '${_forecast.today.high}°',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 76,
                  fontWeight: FontWeight.w200,
                  height: 1,
                ),
              ),
              Text(
                _forecast.today.label,
                style: const TextStyle(color: Colors.white, fontSize: 17),
              ),
              const SizedBox(height: 4),
              Text(
                'H:${_forecast.today.high}°  L:${_forecast.today.low}°',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    // A scrim over the cover's own sky gradient. This screen
                    // is not Miles and must not look like it — it is the
                    // decoy a shoulder-surfer sees, and a stock weather app
                    // washes its forecast panel over the sky exactly so.
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _forecast.week.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                    itemBuilder: (context, i) {
                      final d = _forecast.week[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 46,
                              child: Text(
                                i == 0 ? 'Today' : _weekdayShort(now, i),
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 15,),
                              ),
                            ),
                            Icon(d.icon, color: Colors.white, size: 22),
                            const Spacer(),
                            Text(
                              '${d.low}°',
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 15,),
                            ),
                            const SizedBox(width: 14),
                            SizedBox(
                              width: 34,
                              child: Text(
                                '${d.high}°',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 15,),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _dayLabel(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${_weekdayLong(d.weekday)}, ${months[d.month - 1]} ${d.day}';
  }

  static String _weekdayLong(int w) => const [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday',
        'Friday', 'Saturday', 'Sunday',
      ][w - 1];

  static String _weekdayShort(DateTime from, int offset) => const [
        'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
      ][from.add(Duration(days: offset)).weekday - 1];
}

class _Day {
  const _Day(this.label, this.icon, this.high, this.low);
  final String label;
  final IconData icon;
  final int high;
  final int low;
}

class _Forecast {
  const _Forecast(this.week);

  /// Seeded on the calendar day, so the forecast is stable all day and only
  /// changes overnight — the way a real one behaves. A forecast that reshuffles
  /// on every open is the fastest way to look fake.
  factory _Forecast.forToday() {
    final now = DateTime.now();
    final rnd = math.Random(now.year * 10000 + now.month * 100 + now.day);
    const conditions = [
      ('Sunny', Icons.wb_sunny_rounded),
      ('Partly cloudy', Icons.wb_cloudy_outlined),
      ('Cloudy', Icons.cloud_rounded),
      ('Light rain', Icons.grain_rounded),
    ];
    final base = 18 + rnd.nextInt(14); // a believable 18-31°C band
    return _Forecast(List.generate(7, (i) {
      final c = conditions[rnd.nextInt(conditions.length)];
      final high = base + rnd.nextInt(5) - 2;
      return _Day(c.$1, c.$2, high, high - 6 - rnd.nextInt(3));
    }),);
  }
  final List<_Day> week;

  _Day get today => week.first;
}
