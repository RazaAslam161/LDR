import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/rituals/create_ritual_screen.dart';
import 'package:miles/features/rituals/ritual_repository.dart';

/// List of active rituals for this couple + a "create" entry point.
class RitualsScreen extends ConsumerStatefulWidget {
  const RitualsScreen({super.key});

  @override
  ConsumerState<RitualsScreen> createState() => _RitualsScreenState();
}

class _RitualsScreenState extends ConsumerState<RitualsScreen> {
  List<Ritual>? _rituals;
  String? _error;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await RitualRepository.list(couple.id);
      if (!mounted) return;
      setState(() {
        _rituals = list;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyAuthError(e);
        _busy = false;
      });
    }
  }

  Future<void> _openCreate() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => CreateRitualSheet(coupleId: couple.id),
    );
    if (created ?? false) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Rituals'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: MilesColors.ember,
        foregroundColor: MilesColors.night,
        onPressed: _openCreate,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_busy && _rituals == null) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_error != null) {
      return _MessageState(
        icon: Icons.cloud_off,
        message: _error!,
        action: _load,
        actionLabel: 'Retry',
      );
    }
    final list = _rituals;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) {
      return _MessageState(
        icon: Icons.schedule,
        message:
            'No rituals yet. Add a good-morning or good-night ritual so it '
            'lands in their world at the right time.',
        action: _openCreate,
        actionLabel: 'Add ritual',
      );
    }
    // Soonest upcoming first, then what has already gone by, newest of those
    // first. The query orders by deliver_at ascending, which on this data put
    // eighteen past-due rows above the one the user just made.
    final now = DateTime.now();
    final upcoming = list
        .where((r) => r.deliverAt == null || !r.deliverAt!.toLocal().isBefore(now))
        .toList()
      ..sort(
        (a, b) =>
            (a.deliverAt ?? DateTime(0)).compareTo(b.deliverAt ?? DateTime(0)),
      );
    final past = list
        .where((r) => r.deliverAt != null && r.deliverAt!.toLocal().isBefore(now))
        .toList()
      ..sort((a, b) => b.deliverAt!.compareTo(a.deliverAt!));

    return RefreshIndicator(
      color: MilesColors.ember,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        children: [
          for (final r in upcoming) ...[
            _RitualCard(ritual: r, onRefresh: _load),
            const SizedBox(height: 12),
          ],
          if (past.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'ALREADY PAST',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
                color: MilesColors.faint,
              ),
            ),
            const SizedBox(height: 12),
            for (final r in past) ...[
              _RitualCard(ritual: r, onRefresh: _load),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }
}

class _RitualCard extends ConsumerStatefulWidget {
  const _RitualCard({
    required this.ritual,
    required this.onRefresh,
  });

  final Ritual ritual;
  final VoidCallback onRefresh;

  @override
  ConsumerState<_RitualCard> createState() => _RitualCardState();
}

class _RitualCardState extends ConsumerState<_RitualCard> {
  bool _busy = false;

  /// Runs a write and puts the failure on screen.
  ///
  /// Every one of these used to end in `catch (e) { // Ignore }`, and the
  /// server rejects a delete far more often than it accepts one — deleting is
  /// guarded by a trigger that wants both partners. Swallowing that turned a
  /// refusal the user could have acted on into a button that does nothing.
  Future<void> _run(Future<void> Function() write) async {
    setState(() => _busy = true);
    try {
      await write();
      widget.onRefresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_deleteError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The guard raises two distinct refusals; both read as gibberish raw.
  String _deleteError(Object e) {
    final s = e.toString();
    if (s.contains('must be requested')) {
      return 'Ask to delete this one first.';
    }
    if (s.contains('only your partner')) {
      final them = ref.read(sessionProvider).partner?.displayName ?? 'Your partner';
      return '$them has to confirm this one — or you can remove it yourself '
          'in 14 days.';
    }
    return friendlyAuthError(e);
  }

  Future<void> _requestDelete() async {
    final me = ref.read(sessionProvider).profile?.id;
    if (me == null) return;
    await _run(() => RitualRepository.requestDelete(
          ritualId: widget.ritual.id,
          requestedBy: me,
        ),);
  }

  @override
  Widget build(BuildContext context) {
    final ritual = widget.ritual;
    final type = ritual.type;
    final me = ref.read(sessionProvider).profile?.id;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: MilesColors.tint(const Color(0xFFEF6F58), 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _iconFor(type),
              color: const Color(0xFFF4937E),
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _labelFor(type),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                          color: MilesColors.emberSoft,
                        ),
                      ),
                    ),
                    if (ritual.delivered) ...[
                      const SizedBox(width: 8),
                      const Text(
                        '· sent',
                        style: TextStyle(
                          fontSize: 10,
                          color: MilesColors.taupe,
                        ),
                      ),
                    ],
                    const Spacer(),
                    // Sits on the title line rather than floating under the
                    // message: appended to the bottom of the column it lined up
                    // with nothing and added 48dp of ragged height per card.
                    if (!ritual.deleteRequested)
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          icon: const Icon(Icons.delete_outline,
                              color: MilesColors.faint,),
                          tooltip: 'Ask to delete',
                          onPressed: _busy ? null : _requestDelete,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  ritual.message ?? '(no message)',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
                if (ritual.deliverAt != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(
                        Icons.access_time,
                        size: 14,
                        color: MilesColors.taupe,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _whenLabel(ritual.deliverAt!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: MilesColors.taupe,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (ritual.deleteRequested) ...[
                  const SizedBox(height: 14),
                  _DeleteConsent(
                    mine: ritual.deleteRequestedBy == me,
                    windowElapsed: ritual.deleteWindowElapsed,
                    partnerName:
                        ref.read(sessionProvider).partner?.displayName ??
                            'Your partner',
                    busy: _busy,
                    onCancel: () =>
                        _run(() => RitualRepository.cancelDelete(ritual.id)),
                    onConfirm: () =>
                        _run(() => RitualRepository.confirmDelete(ritual.id)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(RitualType t) {
    switch (t) {
      case RitualType.goodnight:
        return Icons.nights_stay_outlined;
      case RitualType.goodmorning:
        return Icons.wb_sunny_outlined;
      case RitualType.weeklyHighlow:
        return Icons.trending_up;
      case RitualType.custom:
        return Icons.favorite_outline;
    }
  }

  String _labelFor(RitualType t) {
    switch (t) {
      case RitualType.goodnight:
        return 'GOODNIGHT';
      case RitualType.goodmorning:
        return 'GOOD MORNING';
      case RitualType.weeklyHighlow:
        return 'HIGHS & LOWS';
      case RitualType.custom:
        return 'RITUAL';
    }
  }

  /// Says which day as well as which time, and does not promise a delivery
  /// that is already in the past.
  String _whenLabel(DateTime utc) {
    final at = utc.toLocal();
    final time = DateFormat('h:mm a').format(at);
    if (at.isBefore(DateTime.now())) {
      return 'was due ${DateFormat('d MMM').format(at)}, $time';
    }
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final isTomorrow = at.year == tomorrow.year &&
        at.month == tomorrow.month &&
        at.day == tomorrow.day;
    if (isTomorrow) return 'tomorrow, $time';
    return 'arrives ${DateFormat('d MMM').format(at)}, $time';
  }
}

/// The standing delete request, and whichever control this person may use.
///
/// The server decides, not this widget: a request has to exist, and the
/// partner is the one who confirms it unless 14 days have passed. Laying the
/// buttons out in a Column rather than a Row is what stops a long name from
/// overflowing the card.
class _DeleteConsent extends StatelessWidget {
  const _DeleteConsent({
    required this.mine,
    required this.windowElapsed,
    required this.partnerName,
    required this.busy,
    required this.onCancel,
    required this.onConfirm,
  });

  final bool mine;
  final bool windowElapsed;
  final String partnerName;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final String status;
    if (!mine) {
      status = '$partnerName asked to delete this.';
    } else if (windowElapsed) {
      status = 'Waited 14 days — you can remove this yourself now.';
    } else {
      status = 'You asked to delete this. $partnerName needs to agree.';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MilesColors.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status,
            style: const TextStyle(
              color: MilesColors.cream100,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Row(
              children: [
                if (!mine || windowElapsed)
                  TextButton(
                    onPressed: onConfirm,
                    style: TextButton.styleFrom(
                      foregroundColor: MilesColors.ember,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 40),
                    ),
                    child: const Text('Delete', style: TextStyle(fontSize: 13)),
                  ),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: MilesColors.taupe,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 40),
                  ),
                  child: Text(mine ? 'Cancel request' : 'Keep it',
                      style: const TextStyle(fontSize: 13),),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.message,
    required this.action,
    required this.actionLabel,
  });
  final IconData icon;
  final String message;
  final VoidCallback action;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            const SizedBox(height: 24),
            FilledButton(
              onPressed: action,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
