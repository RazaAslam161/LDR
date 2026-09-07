import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_bust.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/timeline/timeline_repository.dart';

class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  List<Visit>? _visits;
  late _Stats _stats;
  String? _error;
  bool _loading = true;

  bool _loadedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Load once, not on every dependency change — a keyboard show/hide or a
    // rotation was refetching the whole list and flashing the spinner. Still
    // driven from here rather than initState so a couple that resolves after
    // the first frame still gets picked up.
    if (_loadedOnce) return;
    if (ref.read(sessionProvider).couple == null) return;
    _loadedOnce = true;
    _load();
  }

  Future<void> _load() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetched = await TimelineRepository.list(couple.id);
      if (!mounted) return;
      // Newest first for the timeline. Sorted and summed here, once per
      // fetch, not in _body on every rebuild. A copy, because the repository
      // hands back an unmodifiable list and sort() on one throws.
      final visits = [...fetched]
        ..sort((a, b) => b.startDate.compareTo(a.startDate));
      setState(() {
        _visits = visits;
        _stats = _Stats.compute(visits);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyAuthError(e);
        _loading = false;
      });
    }
  }

  Future<void> _openAddPast() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B0F16),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _AddPastVisitSheet(coupleId: couple.id),
    );
    if (added ?? false) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Timeline'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFEF6F58),
        foregroundColor: const Color(0xFF0B0F16),
        onPressed: _openAddPast,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off,
        message: _error!,
        action: _load,
        actionLabel: 'Retry',
      );
    }
    final visits = _visits;
    if (visits == null) return const SizedBox.shrink();
    if (visits.isEmpty) {
      return _CenteredMessage(
        icon: Icons.timeline,
        art: 'assets/art/thread.webp',
        message:
            'No visits yet. Add a past trip to start building the story of '
            'the distance — every visit matters.',
        action: _openAddPast,
        actionLabel: 'Add a past visit',
      );
    }

    final ordered = visits;
    final stats = _stats;

    return RefreshIndicator(
      color: const Color(0xFFEF6F58),
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
        children: [
          _StatsHeader(stats: stats),
          const SizedBox(height: 24),
          for (var i = 0; i < ordered.length; i++) ...[
            _TimelineEntry(
              visit: ordered[i],
              daysSincePrevious: i + 1 < ordered.length
                  ? ordered[i + 1].startDate
                      .difference(ordered[i].startDate)
                      .inDays
                  : null,
            ),
            if (i < ordered.length - 1) const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

// ─── Stats ────────────────────────────────────────────────────────────────

class _Stats {
  const _Stats({
    required this.daysTogetherThisYear,
    required this.daysApartSinceLastVisit,
    required this.visitCount,
  });

  final int daysTogetherThisYear;
  final int? daysApartSinceLastVisit;
  final int visitCount;

  static _Stats compute(List<Visit> visits) {
    final thisYear = DateTime.now().year;
    var together = 0;
    for (final v in visits) {
      final end = v.endDate ?? v.startDate;
      if (end.year != thisYear && v.startDate.year != thisYear) continue;
      final start = DateTime(v.startDate.year, v.startDate.month, v.startDate.day);
      final stop = DateTime(end.year, end.month, end.day);
      final days = stop.difference(start).inDays + 1;
      if (days > 0) together += days;
    }

    // Most-recent past visit (or upcoming if none have happened yet).
    final now = DateTime.now();
    DateTime? lastEnd;
    for (final v in visits) {
      if (v.startDate.isBefore(now) && !v.isUpcoming) {
        final end = v.endDate ?? v.startDate;
        if (lastEnd == null || end.isAfter(lastEnd)) lastEnd = end;
      }
    }
    final apart = lastEnd == null
        ? null
        : DateTime(now.year, now.month, now.day)
            .difference(DateTime(lastEnd.year, lastEnd.month, lastEnd.day))
            .inDays;

    return _Stats(
      daysTogetherThisYear: together,
      daysApartSinceLastVisit: apart,
      visitCount: visits.length,
    );
  }
}

class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.stats});
  final _Stats stats;

  @override
  Widget build(BuildContext context) {
    final apart = stats.daysApartSinceLastVisit;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'THIS YEAR',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF4937E),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  value: apart == null ? '—' : '$apart',
                  label: apart == null
                      ? 'days apart'
                      : 'days apart\nsince last visit',
                ),
              ),
              Container(
                width: 1,
                height: 40,
                color: const Color(0x33F5EFE6),
              ),
              Expanded(
                child: _Stat(
                  value: '${stats.daysTogetherThisYear}',
                  label: 'days together\nthis year',
                ),
              ),
              Container(
                width: 1,
                height: 40,
                color: const Color(0x33F5EFE6),
              ),
              Expanded(
                child: _Stat(
                  value: '${stats.visitCount}',
                  label: 'total visits\nrecorded',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w300,
                color: const Color(0xFFFBF8F4),
              ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Color(0x80F5EFE6)),
        ),
      ],
    );
  }
}

// ─── Timeline entry ───────────────────────────────────────────────────────

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.visit, required this.daysSincePrevious});
  final Visit visit;
  final int? daysSincePrevious;

  @override
  Widget build(BuildContext context) {
    final isUpcoming = visit.isUpcoming;
    final dateFmt = DateFormat('MMM d, y');
    final start = visit.startDate.toLocal();
    final end = visit.endDate?.toLocal();
    final dateRange = end == null
        ? dateFmt.format(start)
        : '${dateFmt.format(start)} → ${dateFmt.format(end)}';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Column(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isUpcoming
                        ? const Color(0xFFEF6F58)
                        : const Color(0xFF34D399),
                    border: Border.all(
                      color: const Color(0xFF0B0F16),
                      width: 3,
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: const Color(0x33F5EFE6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        dateRange,
                        style: const TextStyle(
                          color: Color(0xFFFBF8F4),
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isUpcoming)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: MilesColors.tint(
                                const Color(0xFFEF6F58), 0.15,),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'UPCOMING',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFEF6F58),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (visit.location != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.place_outlined,
                          size: 14,
                          color: Color(0x80F5EFE6),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            visit.location!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0x99F5EFE6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (visit.durationDays > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${visit.durationDays} day${visit.durationDays == 1 ? '' : 's'} together',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFF4937E),
                      ),
                    ),
                  ],
                  if (daysSincePrevious != null && daysSincePrevious! > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${daysSincePrevious!} days between',
                      style: const TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Color(0x66F5EFE6),
                      ),
                    ),
                  ],
                  if (visit.note != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      visit.note!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xCCFBF8F4),
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Add past visit sheet ─────────────────────────────────────────────────

class _AddPastVisitSheet extends StatefulWidget {
  const _AddPastVisitSheet({required this.coupleId});
  final String coupleId;

  @override
  State<_AddPastVisitSheet> createState() => _AddPastVisitSheetState();
}

class _AddPastVisitSheetState extends State<_AddPastVisitSheet> {
  DateTime _start = DateTime.now().subtract(const Duration(days: 30));
  DateTime _end = DateTime.now().subtract(const Duration(days: 25));
  final _location = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool isStart) async {
    final initial = isStart ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
        if (_end.isBefore(picked)) _end = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await TimelineRepository.addPastVisit(
        coupleId: widget.coupleId,
        startDate: _start,
        endDate: _end,
        location: _location.text.trim().isEmpty ? null : _location.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = friendlyAuthError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d, y');
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0x33F5EFE6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Add a past visit',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: const Color(0xFFFBF8F4),
                  ),
            ),
            const SizedBox(height: 24),
            _DateRow(
              label: 'FROM',
              value: fmt.format(_start),
              onTap: () => _pickDate(true),
            ),
            const SizedBox(height: 12),
            _DateRow(
              label: 'TO',
              value: fmt.format(_end),
              onTap: () => _pickDate(false),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _location,
              decoration: const InputDecoration(
                hintText: 'Where was it? (city, their place, a trip…)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF6F58)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Add to timeline'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: MilesColors.surface2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0x33F5EFE6).withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF4937E),
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: const TextStyle(color: Color(0xFFFBF8F4)),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.calendar_today,
              size: 16,
              color: Color(0x80F5EFE6),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared empty / error widget ──────────────────────────────────────────

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.message,
    this.action,
    this.actionLabel,
    this.art,
  });

  /// An illustration to show INSTEAD of [icon] — used where the message is
  /// "there is nothing here yet" rather than "something went wrong".
  final String? art;
  final IconData icon;
  final String message;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (art != null)
              Image.asset(art!, width: 132, height: 132)
            else
              Icon(icon, size: 40, color: const Color(0x80F5EFE6)),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFBF8F4),
                fontSize: 15,
                height: 1.5,
              ),
            ),
            if (action != null && actionLabel != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: action, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
