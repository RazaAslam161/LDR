import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/reels/reel_queue_repository.dart';
import 'package:miles/features/reels/share_intake.dart';
import 'package:miles/features/watch/watch_source.dart';
import 'package:url_launcher/url_launcher.dart';

/// Things they send each other to watch.
///
/// Instagram exposes no feed to any third party, so scrolling reels together
/// inside this app is not buildable at any effort — `watch_source.dart` already
/// classifies instagram.com as a site that carries real video and refuses to be
/// embedded. This is the part that survives that limit and is arguably the part
/// that mattered: she finds something, shares it here, and it is waiting for
/// him, with the app remembering who has actually watched it.
class ReelQueueScreen extends ConsumerStatefulWidget {
  const ReelQueueScreen({super.key});

  @override
  ConsumerState<ReelQueueScreen> createState() => _ReelQueueScreenState();
}

class _ReelQueueScreenState extends ConsumerState<ReelQueueScreen>
    with WidgetsBindingObserver {
  Stream<List<SharedReel>>? _stream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainShare());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A share into an app that was already running arrives as onNewIntent
    // while this screen is resuming, so the pending link has to be collected
    // here as well as on first build.
    if (state == AppLifecycleState.resumed) unawaited(_drainShare());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coupleId = ref.read(sessionProvider).couple?.id;
    if (coupleId != null && _stream == null) {
      _stream = ReelQueueRepository.stream(coupleId);
    }
  }

  /// Takes whatever was shared into the app and queues it.
  Future<void> _drainShare() async {
    // A share that arrived while this screen did not exist: the shell drained
    // it and routed here; consume it before asking the platform channel.
    final handed = ShareIntake.handedOff;
    if (handed != null) {
      ShareIntake.handedOff = null;
      if (mounted) await _addUrl(handed);
    }
    final url = ShareIntake.firstUrl(await ShareIntake.take());
    if (url == null || !mounted) return;
    await _addUrl(url);
  }

  Future<void> _addUrl(String url) async {
    final session = ref.read(sessionProvider);
    final coupleId = session.couple?.id;
    final me = session.profile?.id;
    if (coupleId == null || me == null) {
      // The session can still be in flight right after launch. Doing nothing
      // here read as "the add is broken" — say what is actually happening.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still loading. Try that again in a second.'),
        ),
      );
      return;
    }
    try {
      await ReelQueueRepository.add(
        coupleId: coupleId,
        addedBy: me,
        url: url,
        // One parser decides what a link is, shared with Watch Together, so a
        // TikTok is labelled the same way in both places.
        source: resolveWatchLink(url)?.site,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added for both of you')),
      );
    } catch (e, st) {
      // Reported, not swallowed: this bare catch was the only error surface
      // for the whole add, and it destroyed the evidence of WHY — an RLS
      // refusal, a 500 and a dead socket all printed the same sentence.
      ErrorReporter.report(e, st, kind: 'reels');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't add that link. Try again.")),
      );
    }
  }

  Future<void> _open(SharedReel reel) async {
    final me = ref.read(sessionProvider).profile?.id;
    if (me != null) unawaited(ReelQueueRepository.markSeen(reel.id, me));
    final uri = Uri.tryParse(reel.url);
    if (uri == null) return;
    try {
      // externalApplication so Instagram's own app handles it — a reel in a
      // WebView is both against their terms and a worse player than the one
      // already installed.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing on this phone opens that link.')),
      );
    }
  }

  /// The long-press removal, awaited HERE rather than on a discarded future.
  /// The repository rethrows so a failed remove is never silent; bound straight
  /// to a VoidCallback that rethrow had nowhere to land but the zone handler,
  /// which reaches the error table and not the person whose tile did not move.
  Future<void> _remove(String reelId) async {
    try {
      await ReelQueueRepository.remove(reelId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That didn't remove. Try again.")),
      );
    }
  }

  Future<void> _paste() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        title: const Text('Add a link',
            style: TextStyle(color: Color(0xFFFBF8F4), fontSize: 18),),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Color(0xFFFBF8F4)),
          decoration: const InputDecoration(hintText: 'Paste a link'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Add'),),
        ],
      ),
    );
    final raw = url?.trim() ?? '';
    var clean = ShareIntake.firstUrl(raw);
    // A link pasted without its scheme (instagram.com/reel/…) is the common
    // case, not garbage — upgrade it rather than silently doing nothing.
    if (clean == null &&
        raw.isNotEmpty &&
        raw.contains('.') &&
        !raw.contains(' ')) {
      clean = ShareIntake.firstUrl('https://$raw');
    }
    if (clean != null) {
      await _addUrl(clean);
    } else if (raw.isNotEmpty && mounted) {
      // The old behaviour: nothing at all. An add that does nothing and says
      // nothing is indistinguishable from a broken feature.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That doesn't look like a link.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final me = session.profile?.id ?? '';
    final partner = session.partner?.id ?? '';
    final partnerName = session.partner?.displayName ?? 'Them';

    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(title: const Text('Watch list')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _paste,
        icon: const Icon(Icons.add_link),
        label: const Text('Add link'),
      ),
      body: SafeArea(
        child: StreamBuilder<List<SharedReel>>(
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const _Note("Couldn't load the list. Try again.");
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final reels = snap.data!;
            if (reels.isEmpty) {
              return const _Note(
                'Nothing here yet.\n\nTap "Add link" and paste a reel from '
                'Instagram — or anything else. With no cover on you can also '
                'share from the other app and pick this one. It lands here '
                'for both of you.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: reels.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final r = reels[i];
                return _ReelTile(
                  reel: r,
                  fromPartner: r.addedBy != null && r.addedBy != me,
                  partnerName: partnerName,
                  seenByMe: r.seen(me),
                  seenByPartner: partner.isNotEmpty && r.seen(partner),
                  onTap: () => _open(r),
                  onRemove: () => unawaited(_remove(r.id)),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ReelTile extends StatelessWidget {
  const _ReelTile({
    required this.reel,
    required this.fromPartner,
    required this.partnerName,
    required this.seenByMe,
    required this.seenByPartner,
    required this.onTap,
    required this.onRemove,
  });

  final SharedReel reel;
  final bool fromPartner;
  final String partnerName;
  final bool seenByMe;
  final bool seenByPartner;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onRemove,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(14),
          // Unwatched things she sent are the reason to open this screen, so
          // they are the only rows that get an edge.
          border: fromPartner && !seenByMe
              ? Border.all(color: const Color(0x66EF6F58))
              : null,
        ),
        child: Row(
          children: [
            Icon(
              seenByMe ? Icons.check_circle_outline : Icons.play_circle_fill,
              color: seenByMe
                  ? const Color(0x66F5EFE6)
                  : const Color(0xFFEF6F58),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reel.source ?? 'Link',
                    style: const TextStyle(
                      color: Color(0xFFFBF8F4),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reel.note ?? reel.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0x80F5EFE6),),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    fromPartner
                        ? (seenByMe ? 'From $partnerName' : 'New from $partnerName')
                        : seenByPartner
                            ? '$partnerName watched it'
                            : 'Waiting for $partnerName',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: (fromPartner && !seenByMe) || seenByPartner
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

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x99F5EFE6), height: 1.6),),
        ),
      );
}
