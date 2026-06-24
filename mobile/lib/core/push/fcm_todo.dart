/// FCM / background screen-wake for Reach — NOT YET CONFIGURED.
///
/// The FOREGROUND Reach overlay is fully working (see `app_shell.dart`'s reach
/// listener + `ReachOverlayScreen`). Waking the phone when the app is
/// backgrounded or the screen is off requires Firebase Cloud Messaging, which
/// needs the following (intentionally stubbed — there's no Firebase project yet):
///
///  TODO(fcm 1): add `firebase_core` + `firebase_messaging` to pubspec.
///  TODO(fcm 2): add `android/app/google-services.json` from the Firebase
///               console + the Google-services Gradle plugin.
///  TODO(fcm 3): store each device's FCM token (e.g. a `device_tokens` table)
///               on sign-in and on `onTokenRefresh`; delete on sign-out.
///  TODO(fcm 4): a Supabase Edge Function on INSERT to `reach_events` sends an
///               FCM v1 message to the PARTNER's token with:
///                 android.notification.notification_priority = PRIORITY_MAX
///                 fullScreenIntent = true   ← wakes the screen
///               (the manifest already declares USE_FULL_SCREEN_INTENT + WAKE_LOCK).
///  TODO(fcm 5): `flutter_local_notifications` with Importance.max / Priority.max
///               + `fullScreenIntent: true` to render the lock-screen alert; tap
///               → open `/app` and push `ReachOverlayScreen`.
///
/// iOS cannot force-wake the screen — use a high-priority notification + sound
/// (true critical alerts need an Apple entitlement).
class FcmTodo {
  FcmTodo._();
}
