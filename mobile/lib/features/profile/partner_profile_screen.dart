import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/media_source.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/widgets/file_bubble.dart';
import 'package:miles/features/chat/widgets/media_viewer.dart';
import 'package:miles/features/profile/shared_media_repository.dart';
import 'package:miles/features/profile/shared_media_window.dart';
import 'package:url_launcher/url_launcher.dart';

/// The partner, and everything the two of them have sent each other.
///
/// Reached by tapping their name in the chat header or on Home. It takes no
/// arguments on purpose: the couple and the partner come from the session, so
/// there is no id travelling through a route that could still name the previous
/// account's couple after a sign-out on the same handset.
class PartnerProfileScreen extends ConsumerWidget {
  const PartnerProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final partner = session.partner;
    final couple = session.couple;

    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(title: const Text('Profile')),
      body: partner == null || couple == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Link with your partner first.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: MilesColors.taupe),
                ),
              ),
            )
          : DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  _Header(partner: partner),
                  TabBar(
                    labelColor: MilesColors.cream50,
                    unselectedLabelColor: MilesColors.taupe,
                    indicatorColor: MilesColors.ember,
                    tabs: [
                      for (final kind in SharedMediaKind.values)
                        Tab(text: kind.tabLabel),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        for (final kind in SharedMediaKind.values)
                          _Shelf(
                            coupleId: couple.id,
                            kind: kind,
                            partnerName: partner.displayName,
                            myUid: SupabaseService.currentUserId,
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

class _Header extends ConsumerWidget {
  const _Header({required this.partner});

  final Profile partner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(partnerPresenceProvider);
    final online = presence?.isTrulyOnline ?? false;
    final avatar = partner.avatarUrl;
    final status = partner.statusMessage?.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      child: Row(
        children: [
          EmberPress(
            // Their photo, full size, through the viewer every other image in
            // the app opens in — including its save-to-vault button.
            onTap: avatar == null
                ? null
                : () => MediaViewer.openStored(context, chatBucket, avatar,
                    senderName: partner.displayName,),
            child: _Avatar(url: avatar, name: partner.displayName),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(partner.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall,),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (online) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: MilesColors.sage,),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      _presenceLine(presence),
                      style: TextStyle(
                        fontSize: 12,
                        color: online ? MilesColors.sage : MilesColors.taupe,
                      ),
                    ),
                  ],
                ),
                if (status != null && status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(status,
                      style: const TextStyle(
                          color: MilesColors.cream100, fontSize: 13,),),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What is actually known, rather than what would look tidy.
  ///
  /// `isTrulyOnline` and not the stored `is_online` flag: a force-killed app
  /// never writes that flag false, so Home has shown partners as Online for
  /// hours after they put the phone down. Null presence is not offline either —
  /// it is the row not having arrived yet, and saying "Offline" for it would be
  /// the same lie in the other direction.
  static String _presenceLine(Presence? p) {
    if (p == null) return 'Last seen unknown';
    if (p.isTrulyOnline) return 'Online';
    return p.lastSeenText ?? 'Offline';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    final letter = Center(
      child: Text(initial,
          style: const TextStyle(color: MilesColors.cream50, fontSize: 32),),
    );
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: MilesColors.surface2,
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.35), width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      // profiles.avatar_url holds a storage PATH. Image.network on it fails
      // into the initial letter, which is why every partner with a photo looked
      // like a partner without one for the length of every call.
      child: url == null
          ? letter
          : SignedImage(bucket: chatBucket, value: url, placeholder: letter),
    );
  }
}

/// One tab: the couple's messages of a single [SharedMediaKind], paged.
class _Shelf extends StatefulWidget {
  const _Shelf({
    required this.coupleId,
    required this.kind,
    required this.partnerName,
    required this.myUid,
  });

  final String coupleId;
  final SharedMediaKind kind;
  final String partnerName;

  /// Half of this grid is the user's own sends. Saving one to the vault labels
  /// it with who it came from, and "Photo from <partner>" on a photo you took
  /// yourself is the chat's own bug moved to a new screen.
  final String? myUid;

  @override
  State<_Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<_Shelf> {
  final _scroll = ScrollController();
  late final SharedMediaWindow _window = SharedMediaWindow(
    fetch: (beforeSeq) => SharedMediaRepository.page(
        widget.coupleId, widget.kind, beforeSeq: beforeSeq,),
    pageSize: SharedMediaRepository.pageSize,
    partnerName: widget.partnerName,
    myUid: widget.myUid,
  );

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeMore);
    _window.extend();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _window.dispose();
    super.dispose();
  }

  /// Ask a screen before the bottom, so the next page is usually already there
  /// by the time the thumb gets to it.
  void _maybeMore() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels > p.maxScrollExtent - 600) _window.extend();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _window,
      builder: (context, _) {
        if (!_window.loadedOnce) {
          return const Center(child: CircularProgressIndicator());
        }
        final messages = _window.messages;
        if (messages.isEmpty) {
          return _Notice(
            text: _window.failed
                ? "Couldn't load this. Check your connection and try again."
                : widget.kind.emptyText,
            onRetry: _window.failed ? _window.retry : null,
          );
        }

        switch (widget.kind) {
          case SharedMediaKind.media:
            // The tile's real extent, handed to the decoder. Without it a
            // 3000×4000 upload is decoded at full size into a 120dp square —
            // about 48MB a tile, so two of them blow the 100MiB image cache
            // and the rest of the scroll is permanent re-decode churn. The
            // pager shares that cache, so this is the grid's bill and the
            // viewer's.
            final side = (MediaQuery.sizeOf(context).width - 8) / 3;
            return GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _window.length,
              itemBuilder: (_, i) => _MediaTile(
                item: _window.itemAt(i),
                side: side,
                onTap: () =>
                    MediaViewer.open(context, _window, index: i),
              ),
            );
          case SharedMediaKind.file:
            return ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) =>
                  FileBubble(message: messages[i], width: double.infinity),
            );
          case SharedMediaKind.link:
            return ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _LinkRow(message: messages[i]),
            );
        }
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: MilesColors.taupe),),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                child: const Text('Try again',
                    style: TextStyle(color: MilesColors.gilt),),
              ),
          ],
        ),
      ),
    );
  }
}

/// One square in the grid: a photo, or a video with nothing to show for itself.
class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.item,
    required this.side,
    required this.onTap,
  });

  final MediaItem item;
  final double side;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Videos sent before poster frames existed still have nothing a grid can
    // paint — the file is in couple_intimate and fetching 30MB to draw a 120px
    // square is exactly the download this screen must not do. Ones sent since
    // carry a thumbnail and render like any other tile.
    if (item.isVideo && item.thumbPath == null) {
      return EmberPress(
        onTap: onTap,
        child: const ColoredBox(
          color: MilesColors.night,
          child: Center(
            child: Icon(Icons.play_circle_outline,
                color: MilesColors.cream50, size: 32,),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Hero(
        tag: item.heroTag,
        // Through SignedImage rather than the cache directly: a token lives 24
        // hours and a shelf this long outlives one, so a tile that could only
        // read what the page load happened to sign is a grey square from the
        // day after until the app is killed.
        //
        // tilePath, not path: the thumbnail when there is one. This grid used
        // to pull the full original for every square — thirty of them, at
        // several megabytes each, to fill one screen of 120px tiles.
        child: Stack(
          fit: StackFit.expand,
          children: [
            // `height: side` is gone on purpose, and it is the whole fix.
            // memCacheHeight joins the resize key, so a square tile asking for
            // both dimensions could never share its decoded frame with the
            // viewer's underlay, which asks for width alone. The tile and the
            // photo it opens were two decodes of one file, and the "instant"
            // hand-off never happened. BoxFit still squares it.
            SignedImage(
                bucket: item.bucket,
                value: item.tilePath,
                width: side,
                thumb: item.hasThumb,
                decodeWidth: item.tileDecodeWidth,),
            if (item.isVideo)
              const Center(
                child: Icon(Icons.play_circle_outline,
                    color: Colors.white, size: 32,),
              ),
          ],
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final url = SharedMediaRepository.firstUrl(message.body);
    if (url == null) return const SizedBox.shrink();
    final host = Uri.tryParse(url)?.host ?? url;

    return Material(
      color: MilesColors.surface1,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication,),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.link, color: MilesColors.gilt, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),),
                    const SizedBox(height: 2),
                    Text(url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 12,),),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(DateFormat('d MMM').format(message.createdAt),
                  style: const TextStyle(
                      color: MilesColors.faint, fontSize: 11,),),
            ],
          ),
        ),
      ),
    );
  }
}
