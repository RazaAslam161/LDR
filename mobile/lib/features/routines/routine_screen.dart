import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/routines/routine_repository.dart';

/// The couple's daily chart: one list, two columns of ticks.
///
/// Each partner marks their OWN line. A single shared tick would be less
/// information, not more — the reason to keep this together is seeing whether
/// the other one ate, prayed, drank water, and a shared tick cannot say which
/// of you it was.
///
/// Nothing resets at midnight because nothing needs to: a tick is a row keyed
/// by date, so tomorrow starts empty on its own. Each of you rolls over on
/// YOUR local date, which for two people in different timezones is the only
/// answer that is midnight for either.
class RoutineScreen extends ConsumerStatefulWidget {
  const RoutineScreen({super.key});

  @override
  ConsumerState<RoutineScreen> createState() => _RoutineScreenState();
}

class _RoutineScreenState extends ConsumerState<RoutineScreen> {
  Stream<RoutineDay>? _stream;
  String _date = RoutineRepository.today();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coupleId = ref.read(sessionProvider).couple?.id;
    if (coupleId != null && _stream == null) {
      _stream = RoutineRepository.stream(coupleId, _date);
    }
  }

  /// The app is left open overnight constantly on a phone by a bed, so the
  /// chart has to notice the date changed without a restart.
  void _rolloverIfNeeded() {
    final now = RoutineRepository.today();
    if (now == _date) return;
    final coupleId = ref.read(sessionProvider).couple?.id;
    if (coupleId == null) return;
    setState(() {
      _date = now;
      _stream = RoutineRepository.stream(coupleId, now);
    });
  }

  Future<void> _tap(RoutineItem item, int mine) async {
    final me = ref.read(sessionProvider).profile?.id;
    if (me == null) return;
    // A counted line steps up and wraps back to nothing at the target; a plain
    // one toggles. Both are the same call.
    final next = item.isCounted
        ? (mine >= item.targetCount ? 0 : mine + 1)
        : (mine > 0 ? 0 : 1);
    try {
      await RoutineRepository.setCount(
        itemId: item.id,
        userId: me,
        onDate: _date,
        next: next,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That didn't save. Try again.")),
      );
    }
  }

  Future<void> _addCustom() async {
    final session = ref.read(sessionProvider);
    final coupleId = session.couple?.id;
    final me = session.profile?.id;
    if (coupleId == null || me == null) return;

    final result = await showModalBottomSheet<_NewRoutine>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      builder: (_) => const _AddRoutineSheet(),
    );
    if (result == null) return;
    try {
      await RoutineRepository.addCustom(
        coupleId: coupleId,
        createdBy: me,
        title: result.title,
        sortMinutes: result.minutes,
        targetCount: result.target,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't add that. Try again.")),
      );
    }
  }

  Future<void> _remove(RoutineItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        content: Text(
          'Remove "${item.title}" from the chart? It goes for both of you.',
          style: const TextStyle(color: Color(0xFFFBF8F4), height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove'),),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await RoutineRepository.removeCustom(item.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't remove that. Try again.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _rolloverIfNeeded();
    final session = ref.watch(sessionProvider);
    final me = session.profile?.id ?? '';
    final partner = session.partner?.id ?? '';
    final partnerName = session.partner?.displayName ?? 'Them';

    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(title: const Text('Today')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustom,
        icon: const Icon(Icons.add),
        label: const Text('Add routine'),
      ),
      body: SafeArea(
        child: StreamBuilder<RoutineDay>(
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const _Note("Couldn't load the chart. Pull to try again.");
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final day = snap.data!;
            if (day.items.isEmpty) {
              return const _Note('Nothing on the chart yet.');
            }
            final mineDone =
                day.items.where((i) => day.doneBy(i, me)).length;
            return Column(
              children: [
                _Header(
                  done: mineDone,
                  total: day.items.length,
                  partnerName: partnerName,
                  partnerDone:
                      day.items.where((i) => day.doneBy(i, partner)).length,
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                    itemCount: day.items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final item = day.items[i];
                      return _Row(
                        item: item,
                        mine: day.countFor(item.id, me),
                        theirs: day.countFor(item.id, partner),
                        onTap: () => _tap(item, day.countFor(item.id, me)),
                        onRemove:
                            item.isDefault ? null : () => _remove(item),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.done,
    required this.total,
    required this.partnerName,
    required this.partnerDone,
  });

  final int done;
  final int total;
  final String partnerName;
  final int partnerDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('You  $done/$total',
                    style: const TextStyle(
                      color: Color(0xFFFBF8F4),
                      fontWeight: FontWeight.w600,
                    ),),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: total == 0 ? 0 : done / total,
                  backgroundColor: MilesColors.surface2,
                  color: const Color(0xFFEF6F58),
                  minHeight: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$partnerName  $partnerDone/$total',
                    style: const TextStyle(color: Color(0x99F5EFE6))),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: total == 0 ? 0 : partnerDone / total,
                  backgroundColor: MilesColors.surface2,
                  color: const Color(0x66EF6F58),
                  minHeight: 4,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.mine,
    required this.theirs,
    required this.onTap,
    this.onRemove,
  });

  final RoutineItem item;
  final int mine;
  final int theirs;
  final VoidCallback onTap;

  /// Null for seeded lines — removing "Fajr" for the couple is a different
  /// decision from removing something one of them added.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final done = mine >= item.targetCount;
    final theirsDone = theirs >= item.targetCount;
    return InkWell(
      onTap: onTap,
      onLongPress: onRemove,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle : Icons.circle_outlined,
              color: done ? const Color(0xFFEF6F58) : const Color(0x55F5EFE6),
            ),
            const SizedBox(width: 12),
            if (item.emoji != null) ...[
              Text(item.emoji!, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      color: const Color(0xFFFBF8F4),
                      fontWeight: FontWeight.w600,
                      decoration: done ? TextDecoration.lineThrough : null,
                      decorationColor: const Color(0x66F5EFE6),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.isCounted
                        ? '$mine of ${item.targetCount} · ${item.clock}'
                        : item.clock,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0x80F5EFE6),),
                  ),
                ],
              ),
            ),
            // Their column. Read-only by construction — the policy only lets a
            // person write their own row, so this can never be tapped into a
            // claim about someone else.
            Tooltip(
              message: theirsDone ? 'They did this' : 'Not yet',
              child: Icon(
                theirsDone ? Icons.favorite : Icons.favorite_border,
                size: 18,
                color: theirsDone
                    ? const Color(0xFFEF6F58)
                    : const Color(0x33F5EFE6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewRoutine {
  const _NewRoutine(this.title, this.minutes, this.target);
  final String title;
  final int minutes;
  final int target;
}

class _AddRoutineSheet extends StatefulWidget {
  const _AddRoutineSheet();

  @override
  State<_AddRoutineSheet> createState() => _AddRoutineSheetState();
}

class _AddRoutineSheetState extends State<_AddRoutineSheet> {
  final _title = TextEditingController();
  TimeOfDay _at = const TimeOfDay(hour: 9, minute: 0);
  int _target = 1;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.viewInsetsOf(context).bottom + 20,),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('New routine',
              style: TextStyle(
                  color: Color(0xFFFBF8F4),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,),),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            autofocus: true,
            style: const TextStyle(color: Color(0xFFFBF8F4)),
            decoration: const InputDecoration(labelText: 'What is it?'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showTimePicker(
                      context: context, initialTime: _at,);
                  if (picked != null) setState(() => _at = picked);
                },
                icon: const Icon(Icons.schedule, size: 16),
                label: Text(_at.format(context)),
              ),
              const Spacer(),
              // Times per day, so "every hour" is one line that counts rather
              // than eight lines that do not.
              DropdownButton<int>(
                value: _target,
                dropdownColor: MilesColors.surface1,
                items: const [1, 2, 3, 4, 5, 6, 8, 10, 12]
                    .map((n) => DropdownMenuItem(
                        value: n,
                        child: Text(n == 1 ? 'Once' : '$n times',
                            style:
                                const TextStyle(color: Color(0xFFFBF8F4)),),),)
                    .toList(),
                onChanged: (v) => setState(() => _target = v ?? 1),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                final t = _title.text.trim();
                if (t.isEmpty) return;
                Navigator.pop(
                  context,
                  _NewRoutine(t, _at.hour * 60 + _at.minute, _target),
                );
              },
              child: const Text('Add to chart'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x99F5EFE6), height: 1.5),),
        ),
      );
}
