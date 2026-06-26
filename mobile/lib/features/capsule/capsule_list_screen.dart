import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/capsule/capsule_repository.dart';

/// The shelf of time capsules — sealed boxes the couple fills over months,
/// each waiting for its unlock moment.
class CapsuleListScreen extends ConsumerStatefulWidget {
  const CapsuleListScreen({super.key});

  @override
  ConsumerState<CapsuleListScreen> createState() => _CapsuleListScreenState();
}

class _CapsuleListScreenState extends ConsumerState<CapsuleListScreen> {
  List<Capsule> _capsules = const [];
  ManagedSubscription? _channel;
  bool _loading = true;
  String? _coupleId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) {
      setState(() => _loading = false);
      return;
    }
    _coupleId = couple.id;
    _channel = ManagedSubscription.start(
        () => CapsuleRepository.subscribe(couple.id, _load));
    await _load();
  }

  Future<void> _load() async {
    final id = _coupleId;
    if (id == null) return;
    try {
      final list = await CapsuleRepository.list(id);
      if (mounted) setState(() => _capsules = list);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _channel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final linked = _coupleId != null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Time Capsules'),
      ),
      floatingActionButton: linked
          ? FloatingActionButton.extended(
              backgroundColor: MilesColors.ember,
              foregroundColor: MilesColors.cream50,
              onPressed: () async {
                await context.push('/app/capsule/new');
                _load();
              },
              icon: const Icon(Icons.add),
              label: const Text('New capsule'),
            )
          : null,
      body: !linked
          ? const _Centered('Link with your partner to start a capsule.')
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _capsules.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
                      itemCount: _capsules.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (_, i) => _CapsuleCard(
                        capsule: _capsules[i],
                        onTap: () async {
                          await context.push('/app/capsule/view',
                              extra: _capsules[i]);
                          _load();
                        },
                      ),
                    ),
    );
  }
}

String unlockModeLabel(Capsule c) {
  switch (c.unlockMode) {
    case CapsuleUnlockMode.proximity:
      return 'Opens when you\'re together';
    case CapsuleUnlockMode.date:
      return 'Opens on a chosen date';
    case CapsuleUnlockMode.both:
      return 'Opens together, on the day';
  }
}

class _CapsuleCard extends StatelessWidget {
  const _CapsuleCard({required this.capsule, required this.onTap});
  final Capsule capsule;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final opened = capsule.isUnlocked;
    final ready = !opened && capsule.dateConditionMet && !capsule.needsProximity;
    final accent = opened
        ? MilesColors.sage
        : ready
            ? MilesColors.emberSoft
            : MilesColors.blush;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [MilesColors.surface2, MilesColors.surface1],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: opened ? 0.10 : 0.20),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            Text(opened ? '💖' : '🔒', style: const TextStyle(fontSize: 30)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(capsule.title,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  if (opened)
                    Text('Opened — relive it 💫',
                        style: TextStyle(color: accent, fontSize: 12.5))
                  else if (ready)
                    Text('Ready to open ✨',
                        style: TextStyle(color: accent, fontSize: 12.5))
                  else if (capsule.unlockDate != null &&
                      capsule.unlockDate!.isAfter(DateTime.now()))
                    _CountdownText(target: capsule.unlockDate!, color: accent)
                  else
                    Text(unlockModeLabel(capsule),
                        style: TextStyle(color: accent, fontSize: 12.5)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: MilesColors.faint),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎁', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 16),
            Text('Start a capsule',
                style: Theme.of(context).textTheme.displaySmall,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'Fill it with notes, photos, and voice memos over the months '
              'apart. It stays sealed until the day you\'re back together.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live "Opens in 3 days, 4 h" countdown for future date-mode capsules.
class _CountdownText extends StatefulWidget {
  const _CountdownText({required this.target, required this.color});
  final DateTime target;
  final Color color;

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  String _fmt() {
    final d = widget.target.difference(DateTime.now());
    if (d.isNegative) return 'Ready to open ✨';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final mins = d.inMinutes % 60;
    if (days > 0) return 'Opens in $days ${days == 1 ? 'day' : 'days'}, $hours h';
    if (hours > 0) return 'Opens in $hours h $mins m';
    return 'Opens in $mins min';
  }

  @override
  Widget build(BuildContext context) {
    return Text(_fmt(),
        style: TextStyle(color: widget.color, fontSize: 12.5));
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MilesColors.taupe)),
        ),
      );
}
