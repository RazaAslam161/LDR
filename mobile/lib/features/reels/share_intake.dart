import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text shared into the app from another app's share sheet.
///
/// PULL, not push. A share that cold-starts the app delivers the intent before
/// any Dart exists, so a native side that pushed into a channel would drop the
/// link on exactly the path people use most — opening Instagram, hitting share,
/// and landing in an app that was not running.
class ShareIntake {

  ShareIntake._();
  /// A URL the SHELL drained before the queue screen existed. The screen
  /// consumes it first in its own drain; a static because the hand-off
  /// crosses a route push and neither side holds the other's context.
  static String? handedOff;

  static const _channel = MethodChannel('miles/share_intent');

  /// The pending shared text, or null. Native clears it on read, so a link is
  /// consumed once rather than re-added on every resume.
  static Future<String?> take() async {
    try {
      return await _channel.invokeMethod<String>('takeSharedText');
    } on MissingPluginException {
      // iOS, or a build whose native half is older than this Dart. Not an
      // error — the feature is simply absent.
      return null;
    } catch (e) {
      debugPrint('[share] take failed: ${e.runtimeType}');
      return null;
    }
  }

  /// The first http(s) URL inside [text].
  ///
  /// Share sheets rarely hand over a bare link: Instagram sends
  /// "https://www.instagram.com/reel/... " with trailing whitespace, and other
  /// apps prepend a caption. Storing the raw string would make every link
  /// un-openable for the sake of the words around it.
  static String? firstUrl(String? text) {
    if (text == null) return null;
    final m = RegExp(r'https?://\S+').firstMatch(text);
    return m?.group(0);
  }
}
