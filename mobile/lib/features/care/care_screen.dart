import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/core/widgets/partner_bust.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/care/care_repository.dart';
import 'package:miles/features/shell/app_drawer.dart';

class _Preset {
  const _Preset(this.kind, this.emoji, this.label, this.message);
  final String kind;
  final String emoji;
  final String label;
  final String message;
}

const List<_Preset> _presets = [
  _Preset('eat', '🥗', 'Lunch', 'Did you have lunch yet? 🥗'),
  _Preset('eat', '🍲', 'Dinner', 'Time for dinner 🍲'),
  _Preset('eat', '🍳', 'Breakfast', 'Don’t skip breakfast 🍳'),
  _Preset('medicine', '💊', 'Medicine', 'Take your medicine 💊'),
  _Preset('water', '💧', 'Water', 'Drink some water 💧'),
  _Preset('sleep', '😴', 'Sleep', 'Go to sleep, love 😴'),
  _Preset('break', '☕', 'Break', 'Take a little break ☕'),
  _Preset('move', '🚶', 'Stretch', 'Get up and stretch 🚶'),
];

/// Send your partner a gentle reminder; they tap "Done" so you know they did it.
class CareScreen extends ConsumerStatefulWidget {
  const CareScreen({super.key});

  @override
  ConsumerState<CareScreen> createState() => _CareScreenState();
}

class _CareScreenState extends ConsumerState<CareScreen> {
  String? _coupleId;
  String? _myUid;
  ManagedSubscription? _channel;
  List<CareNudge> _nudges = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    _coupleId = session.couple?.id;
    _myUid = session.profile?.id;
    if (_coupleId != null) {
      _channel = ManagedSubscription.start(
          () => CareRepository.subscribe(_coupleId!, _load),);
    }
    _load();
  }

  @override
  void dispose() {
    _channel?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _coupleId;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final n = await CareRepository.list(id);
      if (mounted) {
        setState(() {
          // This replaces the list with the newest page, so every page loaded
          // behind it is gone — and the flag that says whether more exist has
          // to go back with it. _load is reached from initState, from a send,
          // from the Done tap and from realtime, so without this one tap of
          // Done collapsed a list the user had paged through and then claimed
          // there was nothing older.
          _moreNudges = true;
          _nudges = n;
          _loadError = null;
          _loading = false;
        });
      }
    } catch (e) {
      // Falling through to _loading = false alone rendered "No reminders yet."
      // on a failed read — the same screen a genuinely empty history shows.
      if (mounted) {
        setState(() {
          _loadError = friendlyAuthError(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _send(String kind, String message) async {
    final id = _coupleId;
    final uid = _myUid;
    if (id == null || uid == null) return;
    try {
      await CareRepository.send(
          coupleId: id, fromUser: uid, kind: kind, message: message,);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reminder sent 💛')),
        );
      }
      await _load();
    } catch (_) {
      // The "sent 💛" snackbar is the only feedback this screen gives, so a
      // swallowed failure was indistinguishable from the tap not registering.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("That didn't send."),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _send(kind, message),
            ),
          ),
        );
      }
    }
  }

  Future<void> _custom() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Custom reminder',
            style: TextStyle(color: MilesColors.cream50),),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: MilesColors.cream50),
          decoration: const InputDecoration(hintText: 'e.g. Call your mom 💛'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Send'),),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) await _send('custom', text);
  }

  @override
  Widget build(BuildContext context) {
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'them';
    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Care Reminders'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Send $partnerName a little nudge to take care.',
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 12.5,),),
              ),
              // Preset grid
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final p in _presets)
                      EmberPress(
                        onTap: () => _send(p.kind, p.message),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10,),
                          decoration: BoxDecoration(
                            color: MilesColors.surface1,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: MilesColors.gilt.withValues(alpha: 0.2),),
                          ),
                          child: Text('${p.emoji}  ${p.label}',
                              style: const TextStyle(
                                  color: MilesColors.cream50, fontSize: 13,),),
                        ),
                      ),
                    EmberPress(
                      onTap: _custom,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10,),
                        decoration: BoxDecoration(
                          color: MilesColors.tint(MilesColors.blush, 0.16),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: MilesColors.blush.withValues(alpha: 0.4),),
                        ),
                        child: const Text('✏️  Custom',
                            style: TextStyle(
                                color: MilesColors.cream50, fontSize: 13,),),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: MilesColors.surface2, height: 16),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _loadError != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_loadError!,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: MilesColors.taupe,
                                          height: 1.5,),),
                                  const SizedBox(height: 14),
                                  TextButton(
                                      onPressed: _load,
                                      child: const Text('Try again'),),
                                ],
                              ),
                            ),
                          )
                        : _nudges.isEmpty
                        ? const Center(
                            child: Text('No reminders yet.',
                                style: TextStyle(color: MilesColors.taupe),),)
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            // +1 for the tail: either one more page, or the
                            // sentence that explains why the list ends.
                            itemCount: _nudges.length + 1,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) => i == _nudges.length
                                ? _tail()
                                : _nudgeTile(_nudges[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether a page has been asked for and not answered yet.
  bool _loadingMore = false;

  /// False once a short page has proved there is nothing behind it.
  bool _moreNudges = true;

  Future<void> _loadMore() async {
    final id = _coupleId;
    if (_loadingMore || !_moreNudges || id == null || _nudges.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final older =
          await CareRepository.list(id, before: _nudges.last.createdAt);
      if (!mounted) return;
      final have = {for (final n in _nudges) n.id};
      setState(() {
        _moreNudges = older.length >= CareRepository.pageSize;
        _nudges = [..._nudges, ...older.where((n) => have.add(n.id))];
      });
    } catch (e, st) {
      // Not a snackbar: the page the user already has is still on screen and
      // still correct, so this only has to stop pretending there is more.
      // Reported, though — bound-and-dropped was the whole defect class this
      // repo keeps finding.
      ErrorReporter.report(e, st, kind: 'care-page');
      if (mounted) setState(() => _moreNudges = false);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// The end of the list, and why it ends there.
  ///
  /// The retention sweep deletes anything older than 30 days
  /// (20260601005000), and the screen never said so — a reminder simply was
  /// not there any more, which reads as the app having lost it.
  Widget _tail() {
    if (_moreNudges && _nudges.isNotEmpty) {
      return Center(
        child: _loadingMore
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: MilesColors.taupe,),
                ),
              )
            : TextButton(
                onPressed: () => unawaited(_loadMore()),
                child: const Text('Show older',
                    style: TextStyle(color: MilesColors.taupe),),
              ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          'Reminders are kept for 30 days.',
          style: TextStyle(color: MilesColors.faint, fontSize: 12),
        ),
      ),
    );
  }

  /// How long ago, in the shape the rest of the app uses.
  ///
  /// Every tile said only WHAT it was — "For you", "You sent this" — so a
  /// reminder from three weeks ago and one from ten minutes ago were the same
  /// row. On a list that only ever grows, that is the difference between a
  /// reminder and a wall.
  static String _age(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _nudgeTile(CareNudge n) {
    final mine = n.isMine(_myUid);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.message,
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 14,),),
                const SizedBox(height: 2),
                Text(
                  '${mine ? (n.acknowledged ? 'They did it ✓' : 'You sent this') : (n.acknowledged ? 'You marked done ✓' : 'For you')}'
                  ' · ${_age(n.createdAt)}',
                  style: TextStyle(
                      color: n.acknowledged
                          ? MilesColors.sage
                          : MilesColors.taupe,
                      fontSize: 11,),
                ),
              ],
            ),
          ),
          // The recipient (not me) can mark it done.
          if (!mine && !n.acknowledged)
            EmberPress(
              onTap: () async {
                await CareRepository.acknowledge(n.id);
                await _load();
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: MilesColors.tint(MilesColors.sage, 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Done ✅',
                    style: TextStyle(color: MilesColors.cream50, fontSize: 12),),
              ),
            ),
        ],
      ),
    );
  }
}
