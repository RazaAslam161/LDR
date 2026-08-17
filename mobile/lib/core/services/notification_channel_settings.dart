import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/diag/diag.dart';

/// Deep-links into Android's own notification controls.
///
/// Per-type notification control already exists — every channel this app
/// creates gets its own sound / vibration / importance page in system
/// settings — but the only route there was digging through the OS by hand,
/// under whatever name the launcher is currently wearing. This is the missing
/// doorway: the Settings screen's Notifications section calls [open] with a
/// channel id and lands the user straight on that channel's page.
///
/// Rides `miles/updater` because that is the MethodChannel MainActivity
/// already answers app-level queries on. The Kotlin side falls back to the
/// app's notification page when the id is null or the channel has not been
/// created yet (several are lazy — the message channel by the first push, the
/// timer channel by the Timer cover).
class NotificationChannelSettings {
  NotificationChannelSettings._();

  static const _channel = MethodChannel('miles/updater');

  /// Opens the system page for [channelId], or the app's notification page
  /// when the id is null or unknown. Failures surface as a snackbar — a row
  /// that does nothing on tap reads as broken with no explanation.
  static Future<void> open(BuildContext context, {String? channelId}) async {
    try {
      await _channel.invokeMethod<void>(
        'notificationChannelSettings',
        {'id': channelId},
      );
    } catch (e, st) {
      // Reported as well as shown: when the context is already unmounted the
      // snackbar is skipped, and an intent that fails on one OEM's settings
      // app is exactly the fleet-wide class client_errors exists to catch.
      ErrorReporter.report(e, st, kind: 'channel-settings');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't open your phone's notification settings."),
          ),
        );
      }
    }
  }
}
