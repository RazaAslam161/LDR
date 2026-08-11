import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On the very first launch (any device), ask for all the app's permissions in
/// one go, so the user grants everything upfront instead of feature-by-feature.
///
/// Location is deliberately NOT in this list. This runs in the first frame of
/// main.dart — before sign-up, before pairing, before the user has seen a
/// screen — and a cold "share your location?" from an app you have not used yet
/// is a refusal. Worse, Android turns the second refusal into a permanent one,
/// so the blast could burn the permission before the feature was ever
/// mentioned. It is asked for during onboarding instead, with a reason, by
/// LocationService.onboard.
class PermissionsBootstrap {
  PermissionsBootstrap._();

  static const _key = 'perms_requested_v1';

  static Future<void> requestAllOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_key) ?? false) return;
    await prefs.setBool(_key, true);
    try {
      await [
        Permission.camera,
        Permission.microphone,
        Permission.notification,
        Permission.photos,
        Permission.videos,
        Permission.storage,
      ].request();
    } catch (_) {
      // never block startup on a permission hiccup
    }
  }
}
