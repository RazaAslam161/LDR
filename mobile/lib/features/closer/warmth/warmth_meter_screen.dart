import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/closer/warmth/closeness_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Closeness — daily private 1–10 slider, shown on the Closer grid as
/// "Closeness".
/// App only reveals when BOTH scored ≥7. Protects egos from mismatched states.
///
/// The table is still `desire_temps`: that name is on the wire and in every
/// shipped APK, so it is not renamed — only the words around it are.
class WarmthMeterScreen extends ConsumerStatefulWidget {
  const WarmthMeterScreen({super.key});

  @override
  ConsumerState<WarmthMeterScreen> createState() => _WarmthMeterScreenState();
}

class _WarmthMeterScreenState extends ConsumerState<WarmthMeterScreen> {
  double _myScore = 5;
  /// Null means the SERVER did not send it — either they have not set one, or
  /// the reveal has not happened. The difference is deliberately invisible
  /// here; see [_partnerCheckedIn] for the part that is safe to know.
  int? _partnerScore;
  bool _submittedToday = false;
  bool _partnerCheckedIn = false;
  bool _loading = true;
  String? _loadError;
  ManagedSubscription? _channel;
  bool _subscribed = false;

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

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
            .channel('desire_temps:${couple.id}', opts: RealtimeChannelConfig(private: true))
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
    try {
      _apply(await ClosenessRepository.today());
    } catch (e) {
      // This used to be a bare await. A failed read left _loading true and the
      // screen sat on a spinner with nothing said.
      if (!mounted) return;
      setState(() {
        _loadError = "Couldn't reach Closeness. Check your connection.";
        _loading = false;
      });
      debugPrint('closeness load failed: $e');
    }
  }

  /// One place where a [Closeness] becomes screen state, so a read and a write
  /// cannot drift — `set_closeness` returns exactly what `get_closeness` does.
  void _apply(Closeness c) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadError = c.ok
          ? null
          : c.verdict == 'not_authenticated'
              ? 'Sign in again to check in.'
              : null;
      _myScore = (c.mine ?? 5).toDouble();
      _submittedToday = c.submitted;
      _partnerCheckedIn = c.partnerCheckedIn;
      // Never computed here any more. Null means the server withheld it.
      _partnerScore = c.partner;
    });
  }

  Future<void> _submit() async {
    final score = _myScore.round();
    // The range is the server's to enforce — it answers bad_score — but there
    // is no reason to spend a round trip finding that out.
    if (score < 1 || score > 10) {
      _toast('Pick a number between 1 and 10.');
      return;
    }
    try {
      // One call, and it returns the whole state: no second read, so the
      // reveal cannot be computed against a partner score fetched separately.
      _apply(await ClosenessRepository.submit(score));
    } catch (e) {
      if (!mounted) return;
      _toast("Couldn't reach Closeness. Check your connection.");
      debugPrint('closeness submit failed: $e');
    }
  }

  String get _revealMessage {
    if (_loadError != null) return _loadError!;
    if (_partnerScore != null) {
      return "You're both feeling close today ✨\n"
          'They put $_partnerScore. Read it aloud together once.';
    }
    if (_submittedToday) {
      return "Locked in for today.\n"
          "Change today's any time — everyone sees the change.";
    }
    // Knowing they have answered is safe; their number is not, and the server
    // has not sent it. Saying so is what stops the wait feeling like silence.
    if (_partnerCheckedIn) {
      return 'Your partner has checked in for today.\n'
          'Slide to set yours.';
    }
    return 'Slide to set yours.\n'
        "If you both landed at 7 or higher, you'll both be told.";
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
                          'Closeness',
                          style: TextStyle(
                            color: Color(0xFFFBF8F4),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'How close do you feel today?',
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
                          color: MilesColors.surface1,
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
                        Text('1 · low-key',
                            style:
                                TextStyle(color: Color(0x66F5EFE6), fontSize: 11),),
                        Text('10 · all in',
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
