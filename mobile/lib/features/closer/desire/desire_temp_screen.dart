import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Desire Temperature — daily private 1–10 slider.
/// App only reveals when BOTH scored ≥7. Protects egos from mismatched states.
class DesireTempScreen extends ConsumerStatefulWidget {
  const DesireTempScreen({super.key});

  @override
  ConsumerState<DesireTempScreen> createState() => _DesireTempScreenState();
}

class _DesireTempScreenState extends ConsumerState<DesireTempScreen> {
  double _myScore = 5;
  int? _partnerScore; // null = not yet today OR hidden by reveal logic
  bool _submittedToday = false;
  bool _loading = true;
  ManagedSubscription? _channel;
  bool _subscribed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_subscribed) return;
    _subscribed = true;
    _loadToday();
    // Live sync: when the partner locks in their score, re-check the reveal.
    final couple = ref.read(sessionProvider).couple;
    if (couple != null) {
      _channel = ManagedSubscription.start(
        () => SupabaseService.client
            .channel('desire_temps:${couple.id}')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'desire_temps',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'couple_id',
                value: couple.id,
              ),
              callback: (_) => _loadToday(),
            )
            .subscribe(),
      );
    }
  }

  @override
  void dispose() {
    _channel?.dispose();
    super.dispose();
  }

  Future<void> _loadToday() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final today = DateTime.now().toUtc();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final res = await SupabaseService.client
        .from('desire_temps')
        .select('user_id, score')
        .eq('couple_id', couple.id)
        .eq('on_date', todayStr);

    int? mine;
    int? partner;
    for (final row in res as List) {
      final uid = row['user_id'] as String;
      final s = (row['score'] as num).toInt();
      if (uid == me.id) {
        mine = s;
      } else {
        partner = s;
      }
    }

    if (!mounted) return;
    setState(() {
      _myScore = (mine ?? 5).toDouble();
      _submittedToday = mine != null;
      // Reveal logic: only show partner score if BOTH ≥ 7
      if (mine != null && partner != null && mine >= 7 && partner >= 7) {
        _partnerScore = partner;
      } else {
        _partnerScore = null;
      }
      _loading = false;
    });
  }

  Future<void> _submit() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) return;

    final today = DateTime.now().toUtc();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final score = _myScore.round();

    await SupabaseService.client.from('desire_temps').upsert({
      'couple_id': couple.id,
      'on_date': todayStr,
      'user_id': me.id,
      'score': score,
    });

    if (!mounted) return;
    setState(() => _submittedToday = true);

    // Re-check reveal logic with the latest partner score.
    final res = await SupabaseService.client
        .from('desire_temps')
        .select('user_id, score')
        .eq('couple_id', couple.id)
        .eq('on_date', todayStr);

    int? partner;
    for (final row in res as List) {
      final uid = row['user_id'] as String;
      if (uid != me.id) partner = (row['score'] as num).toInt();
    }

    if (!mounted) return;
    setState(() {
      if (partner != null && score >= 7 && partner >= 7) {
        _partnerScore = partner;
      } else {
        _partnerScore = null;
      }
    });
  }

  String get _revealMessage {
    if (_partnerScore != null) {
      return 'Tonight could be ✨';
    }
    if (_submittedToday) {
      return "You're a little out of sync today.\nThat's okay.";
    }
    return "Slide to set yours.\nYour partner won't see the number — "
        'only a nudge if you both feel the same way.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: Color(0x80F5EFE6),),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Desire',
                          style: TextStyle(
                            color: Color(0xFFFBF8F4),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'How much today?',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0x66F5EFE6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            if (_loading)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              // The big number
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _myScore.round().toString(),
                        style: Theme.of(context)
                            .textTheme
                            .displayLarge
                            ?.copyWith(
                              fontSize: 96,
                              fontWeight: FontWeight.w300,
                              color: _colorForScore(_myScore.round()),
                            ),
                      ),
                      const SizedBox(height: 24),
                      // Reveal card
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141B26).withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _partnerScore != null
                                ? const Color(0xFFEF6F58).withValues(alpha: 0.4)
                                : const Color(0x1aF5EFE6),
                          ),
                        ),
                        child: Text(
                          _revealMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFFBF8F4),
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Slider
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFFEF6F58),
                        inactiveTrackColor: const Color(0x1aF5EFE6),
                        thumbColor: const Color(0xFFFBF8F4),
                        overlayColor: const Color(0xFFEF6F58).withValues(alpha: 0.2),
                        trackHeight: 4,
                      ),
                      child: Slider(
                        min: 1,
                        max: 10,
                        divisions: 9,
                        value: _myScore,
                        onChanged: _submittedToday
                            ? null
                            : (v) => setState(() => _myScore = v),
                      ),
                    ),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('1 · eh',
                            style:
                                TextStyle(color: Color(0x66F5EFE6), fontSize: 11),),
                        Text('10 · yes',
                            style:
                                TextStyle(color: Color(0x66F5EFE6), fontSize: 11),),
                      ],
                    ),
                  ],
                ),
              ),

              // Submit
              if (!_submittedToday)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('Lock in for today'),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(bottom: 32),
                  child: Text(
                    'Come back tomorrow.',
                    style: TextStyle(color: Color(0x66F5EFE6), fontSize: 12),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Color _colorForScore(int s) {
    // Cool → warm gradient
    if (s <= 3) return const Color(0xFF60A5FA); // blue
    if (s <= 6) return const Color(0xFFFBBF24); // amber
    if (s <= 8) return const Color(0xFFF4937E); // peach
    return const Color(0xFFEF6F58); // coral hot
  }
}
