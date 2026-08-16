import 'package:flutter/foundation.dart';

/// Cuts every `debugPrint` in a release build.
///
/// 103 call sites across 43 files in `lib/` reach logcat today, and they are
/// not anonymous: they carry partner display names, couple ids, message and
/// reach ids, auth state and Supabase error bodies. Anyone with `adb logcat`
/// and thirty seconds — a repair shop, a border check, a partner holding the
/// unlocked handset — reads the whole relationship out of a device whose entire
/// design goal is to look like a news app. The disguise is only as good as the
/// quietest surface, and logcat was the loudest one.
///
/// `debugPrint` is a mutable top-level in `foundation`, so replacing it here
/// covers the existing sites and every one written after this, with no
/// discipline required at the call site. Debug and profile builds keep their
/// output: the point is what ships, not what a developer sees on a cable.
///
/// Errors are unaffected — `ErrorReporter` (main.dart) is the reporting path
/// and does not go through `debugPrint`.
void silenceLogsInRelease() {
  if (!kReleaseMode) return;
  debugPrint = (String? message, {int? wrapWidth}) {};
}
