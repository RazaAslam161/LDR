import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/links/link_open.dart';
import 'package:miles/core/links/link_target.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/net_image.dart';

/// The card under a message that contains a link.
///
/// Drawn from the URL string alone. Everything on it — platform, kind of thing,
/// handle, and for YouTube the poster frame — is derivable without a request,
/// which is the point: the card is useful the instant the message arrives, and
/// a richer title arriving later is an upgrade rather than the thing that makes
/// it work.
///
/// That matters more than it sounds. Fetching Open Graph tags from the phone
/// would tell Instagram the IP of both partners every time either of them
/// scrolls past this bubble — a repeating access pattern from two residential
/// addresses against one content id, which is a stronger link between the two
/// accounts than anything else this app does. So nothing here touches the
/// network except an image whose host is already known to hold it.
class LinkCard extends StatelessWidget {
  const LinkCard({required this.target, super.key, this.onBubble = false});

  final LinkTarget target;

  /// Rendered inside a chat bubble rather than on the page background.
  final bool onBubble;

  IconData get _icon => switch (target.provider) {
        LinkProvider.youtube => Icons.play_circle_fill,
        LinkProvider.instagram => Icons.camera_alt_outlined,
        LinkProvider.tiktok => Icons.music_note,
        LinkProvider.twitter => Icons.chat_bubble_outline,
        LinkProvider.spotify => Icons.headphones,
        LinkProvider.generic => Icons.link,
      };

  Future<void> _open(BuildContext context) async {
    final ok = await LinkOpen.open(context, target);
    if (ok || !context.mounted) return;
    await Clipboard.setData(ClipboardData(text: target.canonical));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final poster = target.derivedThumbUrl;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GestureDetector(
        onTap: () => _open(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            // Opaque, both branches. A translucent fill would let the bubble's
            // own colour through and this card carries text — the repo has a
            // hygiene test for exactly that, and it caught this.
            color: onBubble ? MilesColors.surface1 : MilesColors.surface2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (poster != null)
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Keyed by the video id, so the same reel shared twice
                        // is one download and one decode.
                        NetImage(poster,
                            cacheKey: 'yt/${target.id}', decodeWidth: 640,),
                        const Center(
                          child: Icon(Icons.play_circle_fill,
                              color: Colors.white, size: 44,),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                  child: Row(
                    children: [
                      Icon(_icon, size: 16, color: MilesColors.ember),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${target.site} · ${target.label}',
                              style: const TextStyle(
                                color: MilesColors.cream50,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              Uri.tryParse(target.canonical)?.host ??
                                  target.canonical,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: MilesColors.taupe, fontSize: 11.5,),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 18, color: MilesColors.faint,),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
