import 'package:flutter/material.dart';
import 'package:miles/core/links/link_target.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opening a shared link, and the one question that is not obvious.
///
/// This app wears a disguise. Tapping a reel launches Instagram, which puts
/// Instagram in the recent-apps list next to a news reader and, if the link was
/// opened from a notification, leaves a trail that is a stronger association
/// than anything in the app itself. That is not a reason to refuse to open
/// links — it is the feature — but it IS a reason not to do it silently the
/// first time, and a reason to offer a way that does not leave the app.
///
/// So: the native app is the default because it is what the user wants and it
/// is the only thing that plays a reel properly, and the choice is stated once
/// rather than assumed forever.
class LinkOpen {
  LinkOpen._();

  /// Open [target] the best way available, asking first when the destination
  /// is a platform whose app would be launched.
  ///
  /// Returns false when nothing could open it, so the caller can say so rather
  /// than appearing to do nothing.
  static Future<bool> open(BuildContext context, LinkTarget target) async {
    final uri = Uri.tryParse(target.canonical);
    if (uri == null) return false;

    // Generic links and Spotify go straight out — there is no meaningful
    // in-app rendering of an arbitrary page, and a browser tab is what the
    // user expects from a link.
    if (target.provider == LinkProvider.generic ||
        target.provider == LinkProvider.spotify) {
      return _launch(uri);
    }

    if (!context.mounted) return false;
    final choice = await showModalBottomSheet<_OpenWhere>(
      context: context,
      backgroundColor: MilesColors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                '${target.label} on ${target.site}',
                style: const TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              // Said plainly. The user chose a disguise; they get to know when
              // an action steps outside it.
              child: Text(
                'Opening it there leaves this app and shows up in your recent '
                'apps.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 12.5),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new, color: MilesColors.ember),
              title: Text('Open in ${target.site}',
                  style: const TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, _OpenWhere.app),
            ),
            ListTile(
              leading: const Icon(Icons.copy, color: MilesColors.taupe),
              title: const Text('Copy link',
                  style: TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, _OpenWhere.copy),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null) return true; // dismissed, not failed
    if (choice == _OpenWhere.copy) return false; // caller copies + tells
    return _launch(uri);
  }

  static Future<bool> _launch(Uri uri) async {
    try {
      // externalApplication so Android's own app-links resolution runs and an
      // Instagram URL reaches Instagram rather than a webview that will show a
      // login wall for a reel.
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      try {
        return await launchUrl(uri);
      } catch (_) {
        return false;
      }
    }
  }
}

enum _OpenWhere { app, copy }
