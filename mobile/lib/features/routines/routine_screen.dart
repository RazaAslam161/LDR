import 'dart:async';

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

  /// The couple and date [_stream] is open on, null when nothing is open.
  ///
  /// The stream used to be assigned once, in didChangeDependencies, under an
  /// `_stream == null` guard — and a Riverpod rebuild does not re-run a
  /// dependency pass: ref.watch marks the element dirty and calls build. So a
  /// mount that happened before the session resolved — every cold start, where
  /// the couple arrives a profile fetch later — left the field null for the
  /// life of the screen, and StreamBuilder rendered a spinner with no data, no
  /// error and nothing a retry could act on. Deriving the stream from the
  /// session on every build is what makes that unrepresentable; this key is
  /// what stops it being rebuilt on every frame.
  ///
  /// Keyed on the COUPLE as well as the date, so a re-pair inside one process
  /// cannot leave the chart subscribed to the couple that ended.
  String? _openFor;

  static String _key(String coupleId, String date) => '$coupleId@$date';

  /// My ticks, applied before the server has heard about them.
  ///
  /// The box used to fill only after a write round trip AND the realtime echo
  /// that follows it re-read the whole chart — two network hops before a
  /// checkbox moved, which on a phone reads as broken rather than slow. The
  /// truth still comes from the stream; this just stops the finger waiting for
  /// it.
  final Map<String, int> _optimistic = {};

  /// Reverts one optimistic tick when its write fails.
  void _rollback(String itemId) {
    if (!mounted) return;
    setState(() => _optimistic.remove(itemId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("That didn't save. Try again.")),
    );
  }

  /// My count for [item], preferring an unconfirmed tap over the server's
  /// value, and dropping the override once the server agrees.
  int _mine(RoutineDay day, RoutineItem item, String me) {
    final server = day.countFor(item.id, me);
    final local = _optimistic[item.id];
    if (local == null) return server;
    if (local == server) {
      // Landed. Drop it after this frame — mutating during build would be a
      // setState inside build().
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _optimistic[item.id] == server) {
          setState(() => _optimistic.remove(item.id));
        }
      });
    }
    return local;
  }

  /// Point the screen at [coupleId]'s chart for today, opening a stream only
  /// when the couple or the date actually changed.
  ///
  /// Called from build and assigns the fields directly rather than through
  /// setState: the StreamBuilder underneath reads them in the same pass. The
  /// midnight rollover folded in here used to be its own build-time call into
  /// setState — a markNeedsBuild during build, which asserts on exactly the
  /// night it exists for, the phone left open by the bed past twelve.
  void _sync(String? coupleId) {
    final date = RoutineRepository.today();
    final want = coupleId == null ? null : _key(coupleId, date);
    if (want == _openFor) return;
    _openFor = want;
    _date = date;
    // Yesterday's unconfirmed ticks are not today's, and neither couple's are
    // the other's. _mine prefers a local override until the server agrees with
    // it, and the new day's server count is zero — so a tap left unconfirmed
    // at 23:59 read as done for the whole of the next day.
    _optimistic.clear();
    _stream =
        coupleId == null ? null : RoutineRepository.stream(coupleId, date);
  }

  /// Rebuilds the stream from scratch, which is the only thing that re-runs a
  /// first load that failed: the error the chart renders comes from a load that
  /// threw before anything was delivered, and the subscriptions underneath only
  /// re-read when the socket resumes — which is not an event a person waiting
  /// on a broken screen can cause.
  void _retry() {
    final coupleId = ref.read(sessionProvider).couple?.id;
    if (coupleId == null) {
      // There is no chart to reopen, so the SESSION is what gets retried: the
      // couple arrives with the profile, and _sync opens the stream on the
      // rebuild that lands it. This used to be the snackbar alone, telling the
      // user to sign out and back in — a button that does nothing to the state
      // it is offered against, which is the class of failure this screen is
      // being fixed for.
      unawaited(ref.read(sessionProvider.notifier).loadProfile());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reloading your account…')),
      );
      return;
    }
    // The key is set beside the stream, never left behind it: _sync would
    // otherwise see an unchanged key on the next build and the retry would
    // last exactly one frame.
    setState(() {
      _date = RoutineRepository.today();
      _openFor = _key(coupleId, _date);
      _stream = RoutineRepository.stream(coupleId, _date);
    });
  }

  void _tap(RoutineItem item, int mine) {
    final me = ref.read(sessionProvider).profile?.id;
    if (me == null) return;
    // A counted line steps up and wraps back to nothing at the target; a plain
    // one toggles. Both are the same call.
    final next = item.isCounted
        ? (mine >= item.targetCount ? 0 : mine + 1)
        : (mine > 0 ? 0 : 1);

    // Paint first. Not awaited: awaiting the write is exactly what made the box
    // fill a beat after the tap.
    setState(() => _optimistic[item.id] = next);
    unawaited(
      RoutineRepository.setCount(
        itemId: item.id,
        userId: me,
        onDate: _date,
        next: next,
      ).catchError((_) => _rollback(item.id)),
    );
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
    final session = ref.watch(sessionProvider);
    _sync(session.couple?.id);
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
          // Keyed on the stream OBJECT so a reopen gets a fresh element and a
          // fresh snapshot. StreamBuilder's own swap keeps the old summary —
          // afterDisconnected/afterConnected only restate the connection, so
          // the error survives into the new subscription — and the retry then
          // sat on the same failure screen for the length of the refetch with
          // nothing to show it had been pressed.
          key: ObjectKey(_stream),
          stream: _stream,
          builder: (context, snap) {
            // Nothing to subscribe to: this build found no couple, so _sync
            // opened nothing. A null stream is ConnectionState.none — no data
            // and no error — and it fell through to the spinner below, which
            // is honest only while the session is still resolving. Once the
            // session has answered, that spinner is the terminal state this
            // screen is being fixed for, so it has to become a failure with a
            // control on it.
            if (_stream == null) {
              return session.loading
                  ? const Center(child: CircularProgressIndicator())
                  : _LoadFailed(
                      message: "Couldn't load your couple.",
                      onRetry: _retry,
                    );
            }
            if (snap.hasError) {
              return _LoadFailed(onRetry: _retry);
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final day = snap.data!;
            if (day.items.isEmpty) {
              return const _Note('Nothing on the chart yet.');
            }
            // Counted through _mine, not day.doneBy, or the bar lags a tick
            // behind the box it is summarising.
            final mineDone = day.items
                .where((i) => _mine(day, i, me) >= i.targetCount)
                .length;
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
                      final mine = _mine(day, item, me);
                      return _Row(
                        item: item,
                        mine: mine,
                        theirs: day.countFor(item.id, partner),
                        partnerName: partnerName,
                        onTap: () => _tap(item, mine),
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
    required this.partnerName,
    required this.onTap,
    this.onRemove,
  });

  final RoutineItem item;
  final int mine;
  final int theirs;
  final String partnerName;
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
            // Their column, named and legible rather than a bare glyph.
            //
            // This was an 18px heart with no label, which is not "seeing each
            // other's progress" — it is a decoration you have to be told the
            // meaning of. Read-only by construction: the policy only lets a
            // person write their own row, so it can never be tapped into a
            // claim about someone else.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theirsDone
                    ? MilesColors.tint(const Color(0xFFEF6F58), 0.18)
                    : MilesColors.surface2,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    theirsDone ? Icons.check : Icons.remove,
                    size: 12,
                    color: theirsDone
                        ? const Color(0xFFEF6F58)
                        : const Color(0x66F5EFE6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    item.isCounted
                        ? '$theirs/${item.targetCount}'
                        : partnerName.split(' ').first,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: theirsDone
                          ? const Color(0xFFEF6F58)
                          : const Color(0x66F5EFE6),
                    ),
                  ),
                ],
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

/// A read that failed, deliberately unlike [_Note] beside it.
///
/// This state was unreachable until the repository stopped swallowing a failed
/// first load, and what it then rendered was the empty state's grey line of
/// text with different words on it, instructing a pull-to-refresh gesture no
/// screen in this feature has ever had. A chart that could not be read looked
/// like a chart with nothing on it, and the only instruction it gave did
/// nothing.
///
/// Two causes reach it and they say so separately: a read that threw, and a
/// build that found no couple to read for. One sentence for both would put the
/// screen back where it started — a state whose text does not name what broke.
class _LoadFailed extends StatelessWidget {
  const _LoadFailed({
    required this.onRetry,
    this.message = "Couldn't load today's chart.",
  });

  final VoidCallback onRetry;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined,
                  color: Color(0xFFEF6F58), size: 32,),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFBF8F4), height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
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
