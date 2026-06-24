import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On the very first launch (any device), ask for all the app's permissions in
/// one go, so the user grants everything upfront instead of feature-by-feature.
class PermissionsBootstrap {
  PermissionsBootstrap._();

  static const _key = 'perms_requested_v1';

  static Future<void> requestAllOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_key) ?? false) return;
    await prefs.setBool(_key, true);
    try {
      await [
        Permission.locationWhenInUse,
        Permission.location,
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
