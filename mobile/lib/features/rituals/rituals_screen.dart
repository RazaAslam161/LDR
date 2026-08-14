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
      backgroundColor: const Color(0xFF0B0F16),
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
        backgroundColor: const Color(0xFFEF6F58),
        foregroundColor: const Color(0xFF0B0F16),
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
    return RefreshIndicator(
      color: const Color(0xFFEF6F58),
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _RitualCard(
          ritual: list[i],
          onRefresh: _load,
        ),
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

  Future<void> _cancelDelete() async {
    setState(() => _busy = true);
    try {
      await RitualRepository.cancelDelete(widget.ritual.id);
      widget.onRefresh();
    } catch (e) {
      // Ignore
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete() async {
    final me = ref.read(sessionProvider).profile?.id;
    if (me == null) return;
    setState(() => _busy = true);
    try {
      await RitualRepository.hardDelete(
        ritualId: widget.ritual.id,
        deletedBy: me,
      );
      widget.onRefresh();
    } catch (e) {
      // Ignore
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestDelete() async {
    final me = ref.read(sessionProvider).profile?.id;
    if (me == null) return;
    setState(() => _busy = true);
    try {
      await RitualRepository.requestDelete(
        ritualId: widget.ritual.id,
        requestedBy: me,
      );
      widget.onRefresh();
    } catch (e) {
      // Ignore
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                    Text(
                      _labelFor(type),
                      style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF4937E),
                      ),
                    ),
                    if (ritual.delivered) ...[
                      const SizedBox(width: 8),
                      const Text(
                        '· delivered',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0x80F5EFE6),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  ritual.message ?? '(no message)',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                if (ritual.deliverAt != null)
                  Row(
                    children: [
                      const Icon(
                        Icons.access_time,
                        size: 14,
                        color: Color(0x80F5EFE6),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'delivers ${DateFormat('h:mm a').format(ritual.deliverAt!.toLocal())}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0x80F5EFE6),
                          ),
                        ),
                      ),
                    ],
                  ),
                if (!ritual.deleteRequested)
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Color(0x66F5EFE6), size: 20),
                      tooltip: 'Request delete',
                      onPressed: _busy ? null : _requestDelete,
                    ),
                  ),
                if (ritual.deleteRequested) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text(
                        'Delete pending',
                        style: TextStyle(
                          color: Color(0xFFEF6F58),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (_busy)
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else ...[
                        if (ritual.deleteRequestedBy == me)
                          TextButton(
                            onPressed: _cancelDelete,
                            child: const Text('Cancel request',
                                style: TextStyle(
                                    color: Color(0x80F5EFE6), fontSize: 12)),
                          )
                        else
                          FilledButton(
                            onPressed: _confirmDelete,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFEF6F58),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            child: const Text('Confirm Delete',
                                style: TextStyle(fontSize: 12)),
                          ),
                      ]
                    ],
                  ),
                ]
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
