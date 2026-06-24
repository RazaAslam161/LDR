import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/countdown/widgets/set_visit_sheet.dart';

class CountdownScreen extends ConsumerStatefulWidget {
  const CountdownScreen({super.key});

  @override
  ConsumerState<CountdownScreen> createState() => _CountdownScreenState();
}

class _CountdownScreenState extends ConsumerState<CountdownScreen> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  bool _done = false;
  String? _nextVisitIso;
  String? _nextVisitLabel;
  DateTime? _nextVisit;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _tick() {
    if (_nextVisit == null) return;
    final now = DateTime.now().toUtc();
    final diff = _nextVisit!.difference(now);
    if (diff.isNegative) {
      setState(() {
        _done = true;
        _remaining = Duration.zero;
      });
    } else {
      setState(() {
        _done = false;
        _remaining = diff;
      });
    }
  }

  Future<void> _loadVisit() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    if (couple == null) return;

    final visit = await SupabaseRepository.fetchNextVisit(couple.id);
    if (!mounted) return;
    setState(() {
      _nextVisit = visit?.startDate;
      _nextVisitIso = visit?.startDate.toIso8601String();
      _nextVisitLabel = visit?.location;
    });
    _tick();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Load once after first build, then again whenever the session changes.
    _loadVisit();
  }

  Future<void> _openSetVisitSheet() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B0F16),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SetVisitSheet(coupleId: couple.id),
    );
    await _loadVisit();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final partnerTz = session.partner?.timezone ?? 'UTC';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your countdown'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _nextVisit == null
              ? _EmptyState(onSet: _openSetVisitSheet)
              : Column(
                  children: [
                    if (_nextVisitLabel != null) ...[
                      Text(
                        'NEXT VISIT · ${_nextVisitLabel!.toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 12,
                          letterSpacing: 3,
                          color: Color(0xFFF4937E),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    Expanded(
                      child: _done
                          ? const _TogetherState()
                          : _CountdownView(
                              remaining: _remaining,
                              partnerTz: partnerTz,
                              targetIso: _nextVisitIso!,
                            ),
                    ),
                    if (!_done)
                      Text(
                        DateFormat('EEEE, MMMM d, y').format(_nextVisit!),
                        style: const TextStyle(
                          color: Color(0x80F5EFE6),
                          fontSize: 13,
                        ),
                      ),
                    TextButton(
                      onPressed: _openSetVisitSheet,
                      child: Text(
                        _nextVisit == null ? 'Set a date' : 'Change date',
                        style: const TextStyle(color: Color(0xFFF4937E)),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _CountdownView extends StatelessWidget {
  const _CountdownView({
    required this.remaining,
    required this.partnerTz,
    required this.targetIso,
  });
  final Duration remaining;
  final String partnerTz;
  final String targetIso;

  @override
  Widget build(BuildContext context) {
    final days = remaining.inDays;
    final hours = remaining.inHours % 24;
    final minutes = remaining.inMinutes % 60;
    final seconds = remaining.inSeconds % 60;

    final units = [
      ('days', days),
      ('hours', hours),
      ('minutes', minutes),
      ('seconds', seconds),
    ];

    String partnerLocalTime;
    try {
      final dt = DateTime.parse(targetIso);
      // Show the visit moment in the *partner's* timezone, not this device's.
      final theirTime = TzHelper.inZone(dt, partnerTz);
      partnerLocalTime = DateFormat('EEE, MMM d · h:mm a').format(theirTime);
    } catch (_) {
      partnerLocalTime = '';
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < units.length; i++) ...[
                _Unit(label: units[i].$1, value: units[i].$2),
                if (i < units.length - 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      ':',
                      style:
                          Theme.of(context).textTheme.displayLarge?.copyWith(
                                color: const Color(0x33F5EFE6),
                              ),
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 32),
          Text(
            "That's $partnerLocalTime their time",
            style: const TextStyle(fontSize: 12, color: Color(0x80F5EFE6)),
          ),
        ],
      ),
    );
  }
}

class _Unit extends StatelessWidget {
  const _Unit({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value.toString().padLeft(value < 100 ? 2 : 0, '0'),
          style: Theme.of(context).textTheme.displayLarge?.copyWith(
                fontWeight: FontWeight.w300,
                color: const Color(0xFFFBF8F4),
              ),
        ),
        const SizedBox(height: 8),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            letterSpacing: 2,
            color: Color(0x80F5EFE6),
          ),
        ),
      ],
    );
  }
}

class _TogetherState extends StatelessWidget {
  const _TogetherState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "You're together.",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.w300,
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Enjoy every minute. ✨',
            style: TextStyle(color: Color(0x80F5EFE6)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSet});
  final VoidCallback onSet;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('✈️', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 12),
          Text(
            "When's your next visit?",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Set a date — even a tentative one. The countdown is '
            'the heartbeat of this space.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0x99F5EFE6)),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onSet,
            child: const Text('Start the countdown'),
          ),
        ],
      ),
    );
  }
}

// Internal helper kept at file end to avoid an unused-symbol warning
// when this screen grows the change-date flow.
// ignore: unused_element
void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: AlertBanner(message: message)),
  );
}
