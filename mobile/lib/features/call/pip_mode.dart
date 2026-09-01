import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/call/call_pip.dart' show CallPip;

/// Android's own picture-in-picture window — the call following you OUT of
/// Miles, the way WhatsApp and Snapchat do it.
///
/// This is a different mechanism from [CallPip], and both are needed. CallPip
/// is a Flutter widget and can only float over Miles' own screens. Leaving the
/// app entirely is an OS-level window, and only the Activity can ask for one.
class PipMode {
  PipMode._();

  static const _channel = MethodChannel('miles/pip');

  /// True while Android is showing the app in a PiP window.
  ///
  /// The disguise cover reads this. The cover is raised on EVERY background and
  /// PiP counts as one, so without the exemption, minimising a call out of the
  /// app would put the News cover in the floating window instead of her face —
  /// useless, and a far louder tell than the call itself.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  static bool _wired = false;

  static void wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pip') {
        active.value = call.arguments == true;
      }
      return null;
    });
  }

  /// Arms or disarms the home-button behaviour.
  ///
  /// Armed, pressing home during a call enters PiP instead of backgrounding —
  /// which is what makes it feel like the call follows you rather than
  /// something you have to remember to do.
  static Future<void> setWanted(bool wanted) async {
    try {
      await _channel.invokeMethod<void>('setWanted', {'wanted': wanted});
    } on MissingPluginException {
      // iOS, or a build whose native half predates this.
    } catch (e) {
      debugPrint('[pip] setWanted: ${e.runtimeType}');
    }
  }

  /// Enters PiP immediately. Returns false when the OS refuses — below API 26,
  /// or PiP disabled for the app in system settings.
  static Future<bool> enterNow() async {
    try {
      return await _channel.invokeMethod<bool>('enterNow') ?? false;
    } catch (e) {
      debugPrint('[pip] enterNow: ${e.runtimeType}');
      return false;
    }
  }
}
