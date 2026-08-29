import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/unlink_quotes.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ceremony's one screen, worn differently by its two people.
///
/// The INITIATOR lives here: a quiet page with one love quote, the days
/// remaining, whatever their partner wrote for them, and one large Re-link
/// button — cancelling is always one tap, any day. The PARTNER gets the
/// mirror: the same quote, the clock, a place to write the one note that
/// appears on the initiator's screen, and Accept for the mutual fast path.
/// Nothing here blocks anybody; the week exists so two people keep talking,
/// which is why "continue to app" is always present and chat keeps working.
class UnlinkScreen extends ConsumerStatefulWidget {
  const UnlinkScreen({super.key});

  @override
  ConsumerState<UnlinkScreen> createState() => _UnlinkScreenState();
}

class _UnlinkScreenState extends ConsumerState<UnlinkScreen> {
  Timer? _tick;
  bool _busy = false;
  String? _note;
  bool _noteLoaded = false;

  @override
  void initState() {
    super.initState();
    UnlinkState.current.addListener(_onState);
    _startTicking();
    unawaited(_loadNote());
  }

  @override
  void dispose() {
    UnlinkState.current.removeListener(_onState);
    _tick?.cancel();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    _noteLoaded = false;
    unawaited(_loadNote());
    setState(() {});
  }

  /// Server-relative and self-cancelling past the deadline, the rewrap
  /// pattern: a 1s tick that stops when there is nothing left to count.
  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      final row = UnlinkState.current.value;
      if (row == null || row.due) t.cancel();
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadNote() async {
    final row = UnlinkState.current.value;
    if (row == null || !row.hasNote) {
      if (mounted) setState(() => _noteLoaded = true);
      return;
    }
    final text = await UnlinkRepository.openNote(row);
    if (!mounted) return;
    setState(() {
      _note = text;
      _noteLoaded = true;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await UnlinkState.load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That didn't go through. Try again."),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _relink() => _run(() async {
        await UnlinkRepository.cancel();
        if (mounted && context.canPop()) context.pop();
      });

  Future<void> _accept() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Accept the unlink?',
            style: TextStyle(color: MilesColors.cream50),),
        content: const Text(
          'A final day begins. Either of you can still change your '
          'mind until it ends.',
          style: TextStyle(color: MilesColors.taupe),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept',
                style: TextStyle(color: MilesColors.danger),),
          ),
        ],
      ),
    );
    if (sure ?? false) await _run(UnlinkRepository.accept);
  }

  Future<void> _writeNote(String coupleId, String existing) async {
    final controller = TextEditingController(text: existing);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Write something for them',
            style: TextStyle(color: MilesColors.cream50),),
        content: TextField(
          controller: controller,
          maxLines: 5,
          maxLength: 1000,
          autofocus: true,
          style: const TextStyle(color: MilesColors.cream50),
          decoration: const InputDecoration(
            hintText: 'They will see this on their screen, beside the '
                'button that brings them back.',
            hintStyle: TextStyle(color: MilesColors.taupe, fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text == null) return;
    await _run(() => UnlinkRepository.writeNote(coupleId, text));
    _noteLoaded = false;
    await _loadNote();
  }

  String _countdown(UnlinkRow row) {
    final left = row.endsAt.difference(ServerClock.now());
    if (left.isNegative) return 'The window has closed';
    final days = left.inDays;
    final hours = left.inHours % 24;
    final minutes = left.inMinutes % 60;
    if (days > 0) {
      return '$days ${days == 1 ? 'day' : 'days'}, $hours h left';
    }
    if (left.inHours > 0) return '${left.inHours} h $minutes m left';
    return '$minutes m left';
  }

  @override
  Widget build(BuildContext context) {
    final row = UnlinkState.current.value;
    final session = ref.watch(sessionProvider);
    final uid = session.profile?.id;
    // A deep link with no ceremony, or one that just ended: nothing to show.
    if (row == null || uid == null) {
      return Scaffold(
        backgroundColor: MilesColors.night,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: const Center(
          child: Text('Nothing here anymore.',
              style: TextStyle(color: MilesColors.taupe),),
        ),
      );
    }

    final mine = row.iAmInitiator(uid);
    final quote = unlinkQuoteForDay();
    final partnerName = session.partner?.displayName ?? 'Your partner';

    return Scaffold(
      backgroundColor: MilesColors.night,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.canPop()
                      ? context.pop()
                      : context.go('/app'),
                  child: const Text('Continue to app',
                      style: TextStyle(color: MilesColors.taupe),),
                ),
              ),
              const Spacer(),
              Text(
                mine
                    ? 'You asked to unlink'
                    : '$partnerName asked to unlink',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.taupe,
                  fontSize: 14,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _countdown(row),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.gilt,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 40),
              Text(
                '“${quote.text}”',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 22,
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '— ${quote.author}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.taupe,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 40),
              if (mine && _noteLoaded && _note != null) ...[
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: MilesColors.surface1,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: MilesColors.gilt.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'From $partnerName',
                        style: const TextStyle(
                          color: MilesColors.gilt,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _note!,
                        style: const TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 15,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
              const Spacer(),
              if (row.due)
                Text(
                  mine
                      ? 'The week has passed. Opening the app again will '
                          'complete the unlink.'
                      : 'The window has closed.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: MilesColors.taupe),
                )
              else if (mine) ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: MilesColors.ember,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _busy ? null : _relink,
                    child: const Text(
                      'Re-link',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: MilesColors.cream50,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'One tap, any day, and this never happened.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: MilesColors.gilt.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                    onPressed: _busy
                        ? null
                        : () => _writeNote(row.coupleId, _note ?? ''),
                    child: Text(
                      row.hasNote
                          ? 'Edit what you wrote'
                          : 'Write something for them',
                      style: const TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (!row.accepted)
                  TextButton(
                    onPressed: _busy ? null : _accept,
                    child: const Text(
                      'Accept unlink',
                      style: TextStyle(color: MilesColors.danger),
                    ),
                  )
                else
                  const Text(
                    'Accepted — a final day is running.',
                    style: TextStyle(color: MilesColors.taupe, fontSize: 12),
                  ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.push('/app/settings/export'),
                child: const Text(
                  'Save your memories',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 13),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
