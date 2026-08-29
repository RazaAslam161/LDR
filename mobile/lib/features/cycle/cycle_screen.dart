import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/app/feature_flags.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/cycle/cycle_repository.dart';
import 'package:miles/features/cycle/love_note_preview_sheet.dart';
import 'package:miles/features/cycle/love_notes_pool.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _period = Color(0xFFE0564B);

class CycleScreen extends ConsumerStatefulWidget {
  const CycleScreen({super.key});

  @override
  ConsumerState<CycleScreen> createState() => _CycleScreenState();
}

class _CycleScreenState extends ConsumerState<CycleScreen> {
  String? _coupleId;
  String? _myUid;
  String? _partnerUid;
  bool _isFemale = false;
  bool _loading = true;
  bool _busy = false;

  // mine (female)
  /// Null until her row has actually been READ. Never a default instance: a
  /// default `CycleSettings` has `shareWithPartner: true`, every control below
  /// writes the whole row back, and `cycle_events_partner_read` gates her
  /// partner's SELECT on that column — so a tracker rendered from defaults
  /// after a failed read turned one stepper tap into consent she never gave.
  CycleSettings? _settings;
  List<CycleEvent> _events = const [];
  bool _onPeriod = false;
  CyclePrediction _pred = const CyclePrediction();

  // partner's (male view)
  bool _partnerLoaded = false;
  bool _partnerShares = false;
  bool _partnerOnPeriod = false;
  CyclePrediction _partnerPred = const CyclePrediction();

  /// Set whenever a read fails, cleared by the next one that lands. Rendered:
  /// a failed read used to be indistinguishable from an empty one.
  String? _loadError;

  ManagedSubscription? _channel;

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    _coupleId = s.couple?.id;
    _myUid = s.profile?.id;
    _partnerUid = s.partner?.id;
    _isFemale = s.profile?.isFemale ?? false;
    final cid = _coupleId;
    if (cid == null) {
      _load();
    } else {
      // ManagedSubscription rather than the hand-rolled unsubscribe-then-
      // re-channel this used to do on every resume: `channel()` never dedupes
      // by topic and `unsubscribe()` only schedules a leave, so the rebuild
      // raced a dead duplicate onto the same topic and her partner's edits
      // stopped arriving with nothing said. The re-read rides with each
      // rebuild — a row written while the socket was down arrives by no other
      // path.
      _channel = ManagedSubscription.start(
        () {
          unawaited(_load());
          return SupabaseService.client
              .channel('cycle_events:$cid',
                  opts: RealtimeChannelConfig(private: true),)
              .onPostgresChanges(
                event: PostgresChangeEvent.all,
                schema: 'public',
                table: 'cycle_events',
                callback: (_) => unawaited(_load()),
              )
              .subscribe();
        },
      );
    }
  }

  @override
  void dispose() {
    _channel?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (_isFemale) {
        final uid = _myUid;
        if (uid == null) {
          // Returning here left the spinner up for the life of the screen —
          // the same silence as the swallowed catch below, one line earlier.
          if (mounted) {
            setState(() {
              _loadError = 'This device lost track of the account. '
                  'Sign out and back in.';
              _loading = false;
            });
          }
          return;
        }
        final events = await CycleRepository.events(uid);
        final settings = await CycleRepository.settings(uid);
        final pred = CyclePrediction.compute(
            CycleRepository.startDates(events), settings,);
        if (mounted) {
          setState(() {
            _events = events;
            _settings = settings;
            _onPeriod = CycleRepository.onPeriod(events);
            _pred = pred;
            _loadError = null;
            _loading = false;
          });
        }
      } else {
        final puid = _partnerUid;
        var shares = false;
        var onP = false;
        var pred = const CyclePrediction();
        if (puid != null) {
          final ps = await CycleRepository.settings(puid);
          if (ps.shareWithPartner) {
            final pe = await CycleRepository.events(puid); // RLS-gated
            shares = true;
            onP = CycleRepository.onPeriod(pe) || ps.onPeriodNow;
            pred = CyclePrediction.compute(CycleRepository.startDates(pe), ps);
          }
        }
        if (mounted) {
          setState(() {
            _partnerLoaded = true;
            _partnerShares = shares;
            _partnerOnPeriod = onP;
            _partnerPred = pred;
            _loadError = null;
            _loading = false;
          });
        }
      }
    } catch (e, st) {
      // This used to clear the spinner and say nothing, which rendered the
      // tracker over a default CycleSettings — `shareWithPartner: true` — and
      // her next stepper tap upserted that default over her real row, silently
      // re-granting her partner's read on her cycle. _settings now stays null
      // until a read lands, so there is no settings card to tap, and on his
      // side a failed read no longer reads as "she keeps it private".
      ErrorReporter.report(e, st, kind: 'cycle');
      if (mounted) {
        setState(() {
          _loadError = friendlyAuthError(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggle(bool on) async {
    final cid = _coupleId;
    final uid = _myUid;
    if (cid == null || uid == null) return;
    setState(() {
      _onPeriod = on;
      _busy = true;
    });
    try {
      await CycleRepository.setOnPeriod(coupleId: cid, userId: uid, on: on);
      await _load();
    } catch (e, st) {
      // The switch moved optimistically and the insert threw into nothing, so
      // a period that was never logged sat on screen as if it had been.
      ErrorReporter.report(e, st, kind: 'cycle');
      if (mounted) {
        setState(() => _onPeriod = !on);
        _toast("That didn't save.", onRetry: () => _toggle(on));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSettings(CycleSettings s) async {
    final cid = _coupleId;
    final uid = _myUid;
    final previous = _settings;
    if (cid == null || uid == null || previous == null) return;
    setState(() => _settings = s);
    try {
      await CycleRepository.saveSettings(userId: uid, coupleId: cid, s: s);
    } catch (e, st) {
      // A failed save left the new value on screen with nothing said, and for
      // the share switch that is a lie about who can read her cycle: she sees
      // "Private to you" while the row the RLS policy reads still says shared.
      ErrorReporter.report(e, st, kind: 'cycle');
      if (mounted) {
        setState(() => _settings = previous);
        _toast("That didn't save.", onRetry: () => _saveSettings(s));
      }
      return;
    }
    await _load();
  }

  void _toast(String m, {required VoidCallback onRetry}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m),
        action: SnackBarAction(label: 'Retry', onPressed: onRetry),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Cycle'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _body(),
                ),
        ),
      ),
    );
  }

  /// Nothing renders from a default: a screen that never read her row shows
  /// the failure, not a tracker, and a screen that read it once keeps the last
  /// good answer with a note saying it is not fresh.
  List<Widget> _body() {
    final err = _loadError;
    if (_isFemale) {
      final settings = _settings;
      if (settings == null) return _loadFailed(err);
      return [
        if (err != null) ..._stale(err),
        ..._femaleTracker(settings),
      ];
    }
    if (!_partnerLoaded) return _loadFailed(err);
    return [
      if (err != null) ..._stale(err),
      ..._partnerView(),
    ];
  }

  List<Widget> _loadFailed(String? err) => [
        _wrapCard(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(err ?? "Couldn't load this — try again.",
                style: const TextStyle(
                    color: MilesColors.cream50, fontSize: 13.5, height: 1.4,),),
            const SizedBox(height: 10),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),),
      ];

  List<Widget> _stale(String err) => [
        _wrapCard(Row(
          children: [
            const Icon(Icons.cloud_off, color: MilesColors.taupe, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Not up to date — $err',
                  style: const TextStyle(
                      color: MilesColors.taupe, fontSize: 12, height: 1.35,),),
            ),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),),
        const SizedBox(height: 14),
      ];

  // ──────────────────────────── Female tracker ───────────────────────────────
  List<Widget> _femaleTracker(CycleSettings settings) {
    final avgCycle =
        CycleRepository.avgCycleLength(_events, settings.avgCycleLength);
    final avgPeriod =
        CycleRepository.avgPeriodLength(_events, settings.avgPeriodLength);
    return [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(colors: [
            _period.withValues(alpha: _onPeriod ? 0.30 : 0.12),
            MilesColors.blush.withValues(alpha: 0.14),
          ],),
          border: Border.all(
              color: _period.withValues(alpha: _onPeriod ? 0.5 : 0.2),),
        ),
        child: Row(
          children: [
            const Text('🩸', style: TextStyle(fontSize: 30)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("I'm on my period",
                      style: TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,),),
                  Text(
                      _onPeriod
                          ? 'Logged — turn off when it ends'
                          : 'Toggle on when it starts',
                      style: const TextStyle(
                          color: MilesColors.taupe, fontSize: 12,),),
                ],
              ),
            ),
            Switch(
              value: _onPeriod,
              activeThumbColor: _period,
              onChanged: _busy ? null : _toggle,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      if (_pred.hasData)
        _infoCard([
          _row('Phase', _pred.phaseLabel),
          if (_pred.dayOfCycle != null)
            _row('Day of cycle', 'Day ${_pred.dayOfCycle} (estimate)'),
          if (_pred.daysUntilNext != null)
            _row(
                'Next period',
                _pred.daysUntilNext! <= 0
                    ? 'around now (estimate)'
                    : 'in ~${_pred.daysUntilNext} days (estimate)',),
        ]),
      if (_pred.hasData) const SizedBox(height: 14),
      _CycleCalendar(
        spans: CycleRepository.spans(_events),
        predictedNext: _pred.nextPeriod,
        predictedLen: avgPeriod,
      ),
      const SizedBox(height: 14),
      _infoCard([
        _row('Average cycle', '$avgCycle days'),
        _row('Average period', '$avgPeriod days'),
        _row('Cycles logged', '${CycleRepository.startDates(_events).length}'),
      ]),
      const SizedBox(height: 14),
      _settingsCard(settings),
      const SizedBox(height: 14),
      _disclaimer(),
    ];
  }

  /// Takes the loaded settings rather than reading the field, so there is no
  /// way to build a control that writes a row this screen never read.
  Widget _settingsCard(CycleSettings settings) {
    final name =
        ref.watch(sessionProvider).partner?.displayName ?? 'your partner';
    return _wrapCard(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Settings', style: _h),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: settings.shareWithPartner,
          activeThumbColor: MilesColors.ember,
          onChanged: (v) => _saveSettings(settings.copyWith(share: v)),
          title: Text('Share with $name',
              style: const TextStyle(color: MilesColors.cream50, fontSize: 14),),
          subtitle: Text(
              settings.shareWithPartner
                  ? 'They see a gentle heads-up — never the details'
                  : 'Private to you',
              style: const TextStyle(color: MilesColors.taupe, fontSize: 12),),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Average cycle length',
              style: TextStyle(color: MilesColors.cream50, fontSize: 14),),
          trailing: _stepper(
            settings.avgCycleLength,
            (v) => _saveSettings(settings.copyWith(cycle: v)),
            min: 20,
            max: 45,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Average period length',
              style: TextStyle(color: MilesColors.cream50, fontSize: 14),),
          trailing: _stepper(
            settings.avgPeriodLength,
            (v) => _saveSettings(settings.copyWith(period: v)),
            min: 2,
            max: 10,
          ),
        ),
      ],
    ),);
  }

  Widget _stepper(int value, ValueChanged<int> onChanged,
      {required int min, required int max,}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon:
              const Icon(Icons.remove_circle_outline, color: MilesColors.gilt),
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        Text('$value',
            style: const TextStyle(color: MilesColors.cream50, fontSize: 15),),
        IconButton(
          icon: const Icon(Icons.add_circle_outline, color: MilesColors.gilt),
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }

  // ──────────────────────────── Partner (male) view ──────────────────────────
  List<Widget> _partnerView() {
    final name = ref.watch(sessionProvider).partner?.displayName ?? 'She';
    if (!_partnerShares) {
      return [
        _wrapCard(Row(
          children: [
            const Icon(Icons.lock_outline, color: MilesColors.taupe),
            const SizedBox(width: 12),
            Expanded(
              child: Text('$name keeps her cycle private right now.',
                  style:
                      const TextStyle(color: MilesColors.taupe, fontSize: 13),),
            ),
          ],
        ),),
      ];
    }
    final until = _partnerPred.daysUntilNext;
    return [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(colors: [
            (_partnerOnPeriod ? _period : MilesColors.blush)
                .withValues(alpha: 0.28),
            MilesColors.ember.withValues(alpha: 0.14),
          ],),
          border: Border.all(
              color: (_partnerOnPeriod ? _period : MilesColors.gilt)
                  .withValues(alpha: 0.4),),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_partnerOnPeriod ? '🩸' : '💛',
                    style: const TextStyle(fontSize: 26),),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _partnerOnPeriod
                        ? '$name started her period'
                        : until == null
                            ? "$name's cycle"
                            : until <= 0
                                ? 'Her period’s expected around now'
                                : 'Next period in ~$until days',
                    style: const TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
                _partnerOnPeriod
                    ? 'Maybe send some care — be extra gentle today 💕'
                    : _partnerPred.partnerNote,
                style: const TextStyle(
                    color: MilesColors.cream50, fontSize: 13.5, height: 1.4,),),
            const SizedBox(height: 8),
            const Text('Estimate only — for closeness, not medical use.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 11),),
          ],
        ),
      ),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: MilesColors.blush,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: _sendCareNote,
          icon: const Icon(Icons.favorite),
          label: const Text('Send a care note'),
        ),
      ),
      // SECRET — reached only via _partnerView() (male partner). The female
      // partner sees _femaleTracker(), so this button is invisible to her.
      // Held back from the public launch, see FeatureFlags.pooledLoveNotes.
      if (FeatureFlags.pooledLoveNotes) ...[
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: GlowButton(
            label: '💌 Send a note',
            color: MilesColors.blush,
            onPressed: _showLoveNote,
          ),
        ),
      ],
    ];
  }

  Future<void> _sendCareNote() async {
    final cid = _coupleId;
    if (cid == null) return;
    try {
      await ChatRepository.sendText(
          cid, 'Thinking of you 💕 take it easy today, I’ve got you.',);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Care note sent 💕')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send — try again.')),
        );
      }
    }
  }

  /// The name the pooled notes address her by. Asked once and remembered,
  /// pre-filled from her profile; returns null if he backs out or leaves it
  /// blank, which aborts before any note is shown — 155 of the 250 paragraphs
  /// are written around the name, and a blank one would ship `{name}` verbatim.
  Future<String?> _ensureRecipientName({bool forceAsk = false}) async {
    final saved = await LoveNoteRecipient.get();
    if (!forceAsk && saved != null) return saved;
    if (!mounted) return null;

    final controller = TextEditingController(
      text: saved ?? ref.read(sessionProvider).partner?.displayName ?? '',
    );
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Who is this for?',
            style: TextStyle(color: MilesColors.cream50),),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(color: MilesColors.cream50),
          decoration: const InputDecoration(hintText: 'Her name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save'),),
        ],
      ),
    );

    if (entered == null || entered.isEmpty) return null;
    await LoveNoteRecipient.set(entered);
    return entered;
  }

  /// Secret love-note sender. Lives ONLY inside _partnerView() (the male
  /// partner's view), so the female partner — who sees _femaleTracker() — never
  /// sees it. Pulls a never-repeating paragraph from the pool, fills in her
  /// name, lets him edit it, then sends it to chat as a plain text message. She
  /// just receives a normal message with no idea a pool or this feature exists.
  Future<void> _showLoveNote() async {
    final name = await _ensureRecipientName();
    if (name == null) return;
    final template = await LoveNotesTracker.getNextNote();
    if (!mounted) return;
    await LoveNotePreviewSheet.show(
      context,
      template: template,
      recipientName: name,
      onRegenerate: _showLoveNote,
      // Re-prompts in place: the sheet stays open and re-renders the same
      // paragraph, so backing out costs neither the note nor his edits.
      onChangeName: () => _ensureRecipientName(forceAsk: true),
      onSend: (text) async {
        final cid = _coupleId;
        if (cid == null) return;
        final body = text.trim();
        if (body.isEmpty) return;
        try {
          await ChatRepository.sendText(cid, body);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Sent 💌'),
                backgroundColor: MilesColors.sage,
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not send — try again.')),
            );
          }
        }
      },
    );
  }

  // ──────────────────────────── Shared bits ──────────────────────────────────
  Widget _disclaimer() => _wrapCard(const Row(
        children: [
          Icon(Icons.info_outline, color: MilesColors.taupe, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'For tracking and closeness only — not for medical, fertility, or '
              'contraception decisions. All predictions are estimates.',
              style: TextStyle(
                  color: MilesColors.taupe, fontSize: 11.5, height: 1.35,),
            ),
          ),
        ],
      ),);

  Widget _infoCard(List<Widget> rows) => _wrapCard(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),);

  Widget _wrapCard(Widget child) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.15)),
        ),
        child: child,
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(color: MilesColors.taupe, fontSize: 13),),
            Text(value,
                style:
                    const TextStyle(color: MilesColors.cream50, fontSize: 14),),
          ],
        ),
      );

  static const _h = TextStyle(
      color: MilesColors.gilt,
      fontSize: 12,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w600,);
}

/// A compact month calendar: logged period days filled, predicted window ringed.
class _CycleCalendar extends StatefulWidget {
  const _CycleCalendar({
    required this.spans,
    required this.predictedNext,
    required this.predictedLen,
  });
  final List<PeriodSpan> spans;
  final DateTime? predictedNext;
  final int predictedLen;

  @override
  State<_CycleCalendar> createState() => _CycleCalendarState();
}

class _CycleCalendarState extends State<_CycleCalendar> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  bool _isPeriodDay(DateTime day) {
    final today = DateUtils.dateOnly(DateTime.now());
    for (final s in widget.spans) {
      final start = DateUtils.dateOnly(s.start);
      final end = s.end != null ? DateUtils.dateOnly(s.end!) : today;
      if (!day.isBefore(start) && !day.isAfter(end)) return true;
    }
    return false;
  }

  bool _isPredicted(DateTime day) {
    final p = widget.predictedNext;
    if (p == null) return false;
    final start = DateUtils.dateOnly(p);
    final end = start.add(Duration(days: widget.predictedLen - 1));
    return !day.isBefore(start) && !day.isAfter(end);
  }

  @override
  Widget build(BuildContext context) {
    final first = _month;
    final daysInMonth = DateUtils.getDaysInMonth(first.year, first.month);
    final leading = first.weekday % 7; // Sun=0
    final today = DateUtils.dateOnly(DateTime.now());

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, color: MilesColors.gilt),
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1),),
              ),
              Text(DateFormat.yMMMM().format(_month),
                  style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,),),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: MilesColors.gilt),
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month + 1),),
              ),
            ],
          ),
          Row(
            children: [
              for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                Expanded(
                  child: Center(
                    child: Text(d,
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 11,),),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < leading; i++) const SizedBox(),
              for (var d = 1; d <= daysInMonth; d++)
                _dayCell(DateTime(first.year, first.month, d), today),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend(_period, 'Period'),
              const SizedBox(width: 16),
              _legend(null, 'Predicted', ring: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayCell(DateTime day, DateTime today) {
    final period = _isPeriodDay(day);
    final predicted = !period && _isPredicted(day);
    final isToday = day == today;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: period ? _period : Colors.transparent,
          border: predicted
              ? Border.all(color: MilesColors.gilt.withValues(alpha: 0.7))
              : isToday
                  ? Border.all(
                      color: MilesColors.cream50.withValues(alpha: 0.4),)
                  : null,
        ),
        child: Center(
          child: Text('${day.day}',
              style: TextStyle(
                  color: period ? Colors.white : MilesColors.cream50,
                  fontSize: 12,
                  fontWeight: isToday ? FontWeight.bold : FontWeight.normal,),),
        ),
      ),
    );
  }

  Widget _legend(Color? fill, String label, {bool ring = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            border: ring
                ? Border.all(color: MilesColors.gilt.withValues(alpha: 0.7))
                : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(color: MilesColors.taupe, fontSize: 11),),
      ],
    );
  }
}
