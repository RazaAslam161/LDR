import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/cycle/cycle_repository.dart';

class CycleScreen extends ConsumerStatefulWidget {
  const CycleScreen({super.key});

  @override
  ConsumerState<CycleScreen> createState() => _CycleScreenState();
}

class _CycleScreenState extends ConsumerState<CycleScreen> {
  String? _coupleId;
  String? _myUid;
  String? _partnerUid;
  bool _loading = true;

  CycleSettings _mySettings = const CycleSettings();
  CyclePrediction _mine = const CyclePrediction();

  bool _partnerShares = false;
  CyclePrediction _partner = const CyclePrediction();

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    _coupleId = session.couple?.id;
    _myUid = session.profile?.id;
    _partnerUid = session.partner?.id;
    reportScreen(ref, 'Cycle');
    _load();
  }

  @override
  void dispose() {
    reportActiveTab(ref);
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _myUid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final myStarts = await CycleRepository.starts(uid);
      final mySettings = await CycleRepository.settings(uid);
      final mine = CyclePrediction.compute(myStarts, mySettings);

      var partnerShares = false;
      var partner = const CyclePrediction();
      final puid = _partnerUid;
      if (puid != null) {
        final ps = await CycleRepository.settings(puid);
        final pStarts = await CycleRepository.starts(puid); // RLS-gated
        if (ps.shareWithPartner && pStarts.isNotEmpty) {
          partnerShares = true;
          partner = CyclePrediction.compute(pStarts, ps);
        }
      }

      if (mounted) {
        setState(() {
          _mySettings = mySettings;
          _mine = mine;
          _partnerShares = partnerShares;
          _partner = partner;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logToday() => _logDate(DateTime.now());

  Future<void> _logPicked() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 120)),
      lastDate: DateTime.now(),
    );
    if (picked != null) await _logDate(picked);
  }

  Future<void> _logDate(DateTime d) async {
    final id = _coupleId, uid = _myUid;
    if (id == null || uid == null) return;
    await CycleRepository.logPeriodStart(coupleId: id, userId: uid, date: d);
    await _load();
  }

  Future<void> _saveSettings(CycleSettings s) async {
    final id = _coupleId, uid = _myUid;
    if (id == null || uid == null) return;
    setState(() => _mySettings = s);
    await CycleRepository.saveSettings(userId: uid, coupleId: id, s: s);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Cycle'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
          ),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_partnerShares) _partnerCard(),
                    _myCard(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _partnerCard() {
    final name = ref.watch(sessionProvider).partner?.displayName ?? 'Them';
    final until = _partner.daysUntilNext;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(colors: [
          MilesColors.blush.withValues(alpha: 0.22),
          MilesColors.ember.withValues(alpha: 0.14),
        ]),
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$name right now', style: _h),
          const SizedBox(height: 6),
          Text(_partner.phaseLabel,
              style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          if (until != null) ...[
            const SizedBox(height: 2),
            Text(
                until <= 0
                    ? 'Period due around now'
                    : 'Next period in ~$until days',
                style: const TextStyle(color: MilesColors.taupe, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Text(_partner.partnerNote,
              style: const TextStyle(
                  color: MilesColors.cream50, fontSize: 13.5, height: 1.35)),
        ],
      ),
    );
  }

  Widget _myCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('My cycle', style: _h),
          const SizedBox(height: 10),
          if (_mine.hasData) ...[
            _row('Phase', _mine.phaseLabel),
            if (_mine.dayOfCycle != null)
              _row('Day of cycle', 'Day ${_mine.dayOfCycle}'),
            if (_mine.nextPeriod != null)
              _row(
                  'Next period',
                  '${DateFormat('MMM d').format(_mine.nextPeriod!)}'
                      '${_mine.daysUntilNext != null ? '  (~${_mine.daysUntilNext} days)' : ''}'),
            const SizedBox(height: 12),
          ] else
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                  'Log when your period starts and I’ll predict the next one + your phases.',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12.5)),
            ),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                    onPressed: _logToday,
                    child: const Text('Period started today')),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                  onPressed: _logPicked, child: const Text('Another day')),
            ],
          ),
          const Divider(color: MilesColors.surface2, height: 28),
          _stepper('Average cycle length', _mySettings.avgCycleLength, 21, 35,
              (v) => _saveSettings(_mySettings.copyWith(cycle: v)), 'days'),
          const SizedBox(height: 8),
          _stepper('Average period length', _mySettings.avgPeriodLength, 2, 9,
              (v) => _saveSettings(_mySettings.copyWith(period: v)), 'days'),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _mySettings.shareWithPartner,
            activeThumbColor: MilesColors.ember,
            onChanged: (v) =>
                _saveSettings(_mySettings.copyWith(share: v)),
            title: const Text('Share a gentle summary with my partner',
                style: TextStyle(color: MilesColors.cream50, fontSize: 13)),
            subtitle: const Text('They see your phase + a kind note — never your logs',
                style: TextStyle(color: MilesColors.taupe, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: MilesColors.taupe, fontSize: 13)),
            Text(v,
                style: const TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      );

  Widget _stepper(String label, int value, int min, int max,
      ValueChanged<int> onChanged, String unit) {
    return Row(
      children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: MilesColors.cream50, fontSize: 13))),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline,
              color: MilesColors.taupe, size: 22),
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 54,
          child: Text('$value $unit',
              textAlign: TextAlign.center,
              style: const TextStyle(color: MilesColors.cream50, fontSize: 13)),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline,
              color: MilesColors.taupe, size: 22),
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }

  static const _h = TextStyle(
      color: MilesColors.gilt,
      fontSize: 11,
      letterSpacing: 1.2,
      fontWeight: FontWeight.w600);
}
