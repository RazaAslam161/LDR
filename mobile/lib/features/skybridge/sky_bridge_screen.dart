import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// The Sky Bridge — shows you, at a glance, what the sky looks like right now
/// in your partner's world vs. yours. No timezone math, just colour.
class SkyBridgeScreen extends ConsumerStatefulWidget {
  const SkyBridgeScreen({super.key});

  @override
  ConsumerState<SkyBridgeScreen> createState() => _SkyBridgeScreenState();
}

class _SkyBridgeScreenState extends ConsumerState<SkyBridgeScreen> {
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final me = session.profile;
    final partner = session.partner;

    if (me == null || partner == null) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Waiting for your partner to join…',
            style: TextStyle(color: Color(0x80F5EFE6)),
          ),
        ),
      );
    }

    final nowUtc = DateTime.now().toUtc();

    return Scaffold(
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Sky Bridge'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Two skies. One moment.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0x99F5EFE6),
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _SkyCard(
                  name: me.displayName,
                  timezone: me.timezone,
                  utcMoment: nowUtc,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _SkyCard(
                  name: partner.displayName,
                  timezone: partner.timezone,
                  utcMoment: nowUtc,
                  accent: const Color(0xFFF4937E),
                ),
              ),
              const SizedBox(height: 16),
              _TimeDifferenceCard(
                tzA: me.timezone,
                tzB: partner.timezone,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One partner's sky — gradient + local time + a contextual line.
class _SkyCard extends StatelessWidget {
  const _SkyCard({
    required this.name,
    required this.timezone,
    required this.utcMoment,
    this.accent = const Color(0xFF34D399),
  });
  final String name;
  final String timezone;
  final DateTime utcMoment;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final sky = _describeSky(utcMoment, timezone);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: sky.gradient,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      timezone.replaceAll('_', ' '),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Text(
                  sky.emoji,
                  style: const TextStyle(fontSize: 32),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sky.localTimeLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sky.poeticLine,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeDifferenceCard extends StatelessWidget {
  const _TimeDifferenceCard({required this.tzA, required this.tzB});
  final String tzA;
  final String tzB;

  @override
  Widget build(BuildContext context) {
    final diff = _offsetDifference(tzA, tzB);
    final sign = diff >= 0 ? '+' : '';
    final phrase = diff == 0
        ? "You're in the same timezone."
        : "They're $sign${diff.abs()}h ${diff >= 0 ? 'ahead of' : 'behind'} you.";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141B26).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.hourglass_empty, color: Color(0xFFF4937E), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              phrase,
              style: const TextStyle(color: Color(0xFFFBF8F4), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  int _offsetDifference(String a, String b) => TzHelper.offsetHours(a, b);
}

class _SkyDescription {
  _SkyDescription({
    required this.gradient,
    required this.localTimeLabel,
    required this.poeticLine,
    required this.emoji,
  });

  final List<Color> gradient;
  final String localTimeLabel;
  final String poeticLine;
  final String emoji;
}

/// Builds a colour-gradient + poetic line for a given UTC moment in a TZ.
///
/// For v1 we rely on the device's local interpretation of the UTC instant
/// (since the `timezone` package needs tzdata setup). Once added, swap
/// _localHour to use it. The sky bands are good enough to be evocative:
///   0–5   → deep night
///   5–7   → dawn
///   7–11  → morning
///   11–16 → midday
///   16–19 → golden hour / sunset
///   19–21 → dusk
///   21–24 → night
_SkyDescription _describeSky(DateTime utcMoment, String timezone) {
  // Convert the shared UTC instant into the *partner's* wall-clock time so the
  // sky reflects their world, not this device's.
  final local = TzHelper.inZone(utcMoment, timezone);
  final localHour = local.hour;

  String fmt(int h, int m) {
    final period = h >= 12 ? 'PM' : 'AM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:${m.toString().padLeft(2, '0')} $period';
  }

  final label = fmt(local.hour, local.minute);

  if (localHour < 5) {
    return _SkyDescription(
      gradient: const [Color(0xFF0B0F16), Color(0xFF1B2230)],
      localTimeLabel: label,
      poeticLine: 'Deep night. Probably asleep.',
      emoji: '🌙',
    );
  } else if (localHour < 7) {
    return _SkyDescription(
      gradient: const [Color(0xFF3D2C4E), Color(0xFFE0553D)],
      localTimeLabel: label,
      poeticLine: 'Dawn breaking.',
      emoji: '🌅',
    );
  } else if (localHour < 11) {
    return _SkyDescription(
      gradient: const [Color(0xFF4F86C6), Color(0xFF9CC3F2)],
      localTimeLabel: label,
      poeticLine: 'Soft morning light.',
      emoji: '☀️',
    );
  } else if (localHour < 16) {
    return _SkyDescription(
      gradient: const [Color(0xFF57A0D3), Color(0xFFFFE066)],
      localTimeLabel: label,
      poeticLine: 'Bright midday.',
      emoji: '🌞',
    );
  } else if (localHour < 19) {
    return _SkyDescription(
      gradient: const [Color(0xFFE0553D), Color(0xFFF4937E)],
      localTimeLabel: label,
      poeticLine: 'Golden hour.',
      emoji: '🌇',
    );
  } else if (localHour < 21) {
    return _SkyDescription(
      gradient: const [Color(0xFF4B2E5E), Color(0xFFE0553D)],
      localTimeLabel: label,
      poeticLine: 'Fading dusk.',
      emoji: '🌆',
    );
  } else {
    return _SkyDescription(
      gradient: const [Color(0xFF0B0F16), Color(0xFF1F2937)],
      localTimeLabel: label,
      poeticLine: 'Quiet night.',
      emoji: '🌙',
    );
  }
}
