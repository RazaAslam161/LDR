import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/config.dart';
import 'package:miles/core/app/root_scaffold_key.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/features/breath/widgets/breath_orb.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A shared breathing pacer. When one partner taps "Begin", both phones
/// pulse in unison across the world, following the 4-7-8 relaxation breath.
class BreathSyncScreen extends ConsumerStatefulWidget {
  const BreathSyncScreen({super.key});

  @override
  ConsumerState<BreathSyncScreen> createState() => _BreathSyncScreenState();
}

class _BreathSyncScreenState extends ConsumerState<BreathSyncScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  ManagedSubscription? _channel;
  Timer? _cycleTimer;

  BreathPhase _phase = BreathPhase.idle;
  int _cycleStart = 0; // ms since epoch when current cycle began
  bool _partnerActive = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: BreathPattern.inhaleSeconds),
    );
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    unawaited(MilesSound.stopBed());
    _channel?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _attachChannel(String coupleId) {
    if (_channel != null) return;
    _channel = ManagedSubscription.start(() => SupabaseService.client
        .channel('breath:$coupleId', opts: const RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'breath_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) {
            final startedAt = payload.newRecord['started_at'] as int?;
            final fromPartner =
                payload.newRecord['user_id'] != SupabaseService.currentUserId;
            if (startedAt != null && fromPartner) {
              _onPartnerStartedCycle(startedAt);
            }
          },
        )
        .subscribe(),);
  }

  void _onPartnerStartedCycle(int startedAtMs) {
    // A partner event arrived → they're clearly here. Surface presence even if
    // the event is slightly stale (we still skip *animating* a stale cycle).
    if (mounted && !_partnerActive) {
      setState(() => _partnerActive = true);
    }
    // The JOINER's bed: their partner started the session, so this side never
    // passes through _beginCycle's idle guard — without this, only the person
    // who pressed Begin ever heard the room.
    if (_phase == BreathPhase.idle) unawaited(MilesSound.startBed());
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedMs = now - startedAtMs;
    // If we're more than one full cycle behind, ignore (likely a stale event).
    if (elapsedMs > BreathPattern.totalCycleSeconds * 1000) return;
    _beginCycleFromOffset(elapsedMs);
  }

  Future<void> _beginCycle() async {
    if (_phase == BreathPhase.idle) unawaited(MilesSound.startBed());
    final coupleId = ref.read(sessionProvider).couple!.id;
    _cycleStart = DateTime.now().millisecondsSinceEpoch;
    unawaited(_broadcastStart(coupleId, _cycleStart));
    _beginCycleFromOffset(0);
  }

  Future<void> _broadcastStart(String coupleId, int startedAtMs) async {
    // Write to a tiny table so the realtime channel can fan out.
    await SupabaseService.client.from('breath_events').insert({
      'couple_id': coupleId,
      'user_id': SupabaseService.currentUserId,
      'started_at': startedAtMs,
    });
  }

  void _beginCycleFromOffset(int offsetMs) {
    _cycleTimer?.cancel();
    setState(() => _phase = BreathPhase.inhale);
    MilesSound.cue(Cue.breathIn);
    _pulse.duration =
        const Duration(seconds: BreathPattern.inhaleSeconds);
    _pulse.forward(from: (offsetMs / Breed.inhaleMs).clamp(0, 1));

    final remainingInhale =
        (BreathPattern.inhaleSeconds * 1000 - offsetMs).clamp(0, BreathPattern.inhaleSeconds * 1000);
    _cycleTimer = Timer(Duration(milliseconds: remainingInhale), () {
      setState(() => _phase = BreathPhase.hold);
      const remainingHold = BreathPattern.holdSeconds * 1000;
      _cycleTimer = Timer(const Duration(milliseconds: remainingHold), () {
        setState(() => _phase = BreathPhase.exhale);
        MilesSound.cue(Cue.breathOut);
        _pulse.duration =
            const Duration(seconds: BreathPattern.exhaleSeconds);
        _pulse.reverse(from: 1);
        _cycleTimer = Timer(
          const Duration(seconds: BreathPattern.exhaleSeconds),
          _beginCycle,
        );
      });
    });
  }

  void _stop() {
    unawaited(MilesSound.stopBed());
    _cycleTimer?.cancel();
    _pulse.stop();
    setState(() => _phase = BreathPhase.idle);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;

    if (couple != null) {
      _attachChannel(couple.id);
    }

    final phaseLabel = switch (_phase) {
      BreathPhase.idle => '',
      BreathPhase.inhale => 'Breathe in',
      BreathPhase.hold => 'Hold',
      BreathPhase.exhale => 'Breathe out',
    };

    return Scaffold(
      appBar: AppBar(
        
        title: const Text('Breath Sync'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            if (_partnerActive)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Your partner is here',
                  style: TextStyle(color: Color(0xFF34D399), fontSize: 13),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  "Tap begin — they'll feel it the moment they arrive",
                  style: TextStyle(color: Color(0x80F5EFE6), fontSize: 13),
                ),
              ),
            const Spacer(),
            BreathOrb(
              controller: _pulse,
              phase: _phase,
            ),
            const SizedBox(height: 24),
            Text(
              phaseLabel,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w300,
                    color: const Color(0xFFFBF8F4),
                  ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(24),
              child: _phase == BreathPhase.idle
                  ? FilledButton(
                      onPressed: couple == null ? null : _beginCycle,
                      child: const Text('Begin'),
                    )
                  : OutlinedButton(
                      onPressed: _stop,
                      child: const Text('Stop'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

enum BreathPhase { idle, inhale, hold, exhale }

// Tiny helper namespace used in offset math above.
class Breed {
  Breed._();
  static int get inhaleMs => BreathPattern.inhaleSeconds * 1000;
}
