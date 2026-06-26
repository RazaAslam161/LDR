import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/features/cycle/cycle_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _period = Color(0xFFE0564B);

/// A gentle dashboard card for the male partner: shows when she's on her period
/// or her next period is near (only if she shares). Renders nothing otherwise.
class PartnerCycleCard extends ConsumerStatefulWidget {
  const PartnerCycleCard({super.key});

  @override
  ConsumerState<PartnerCycleCard> createState() => _PartnerCycleCardState();
}

class _PartnerCycleCardState extends ConsumerState<PartnerCycleCard> {
  bool _show = false;
  bool _onPeriod = false;
  int? _daysUntil;
  String? _partnerUid;
  ManagedSubscription? _ch;

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    // Only the male partner sees this card.
    if (!(s.profile?.isMale ?? false)) return;
    _partnerUid = s.partner?.id;
    final cid = s.couple?.id;
    _load();
    if (cid != null) {
      _ch = ManagedSubscription.start(() => SupabaseService.client
          .channel('home_cycle:$cid')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'cycle_events',
            callback: (_) => _load(),
          )
          .subscribe());
    }
  }

  @override
  void dispose() {
    _ch?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final puid = _partnerUid;
    if (puid == null) return;
    try {
      final ps = await CycleRepository.settings(puid);
      if (!ps.shareWithPartner) {
        if (mounted) setState(() => _show = false);
        return;
      }
      final events = await CycleRepository.events(puid);
      final onP = CycleRepository.onPeriod(events) || ps.onPeriodNow;
      final pred =
          CyclePrediction.compute(CycleRepository.startDates(events), ps);
      // Only surface when there's something gentle to say.
      final show = onP || (pred.daysUntilNext != null);
      if (mounted) {
        setState(() {
          _show = show;
          _onPeriod = onP;
          _daysUntil = pred.daysUntilNext;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _show = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final name = ref.watch(sessionProvider).partner?.displayName ?? 'She';
    final text = _onPeriod
        ? '$name started her period — send some care 💕'
        : (_daysUntil != null && _daysUntil! <= 0)
            ? 'Her period’s expected around now 💛'
            : 'Next period in ~$_daysUntil days 💛';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: GestureDetector(
        onTap: () => context.push('/app/cycle'),
        child: GlassPanel(
          child: Row(
            children: [
              Text(_onPeriod ? '🩸' : '💛',
                  style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text,
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 13.5)),
              ),
              Icon(Icons.chevron_right,
                  color: (_onPeriod ? _period : MilesColors.gilt)
                      .withValues(alpha: 0.8)),
            ],
          ),
        ),
      ),
    );
  }
}
