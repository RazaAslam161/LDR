import 'package:flutter/foundation.dart';

/// Ticks whenever the app resumes and the realtime socket was reset (the shell
/// hard-resets the Supabase socket on resume because it dies silently in
/// Android doze). EVERY per-screen realtime subscription should listen to this
/// and re-subscribe its channel, so sync survives backgrounding everywhere —
/// not just the always-on channels (chat/reach/call/presence).
///
/// Usage in a State:
///   initState  → realtimeResumed.addListener(_subscribe);
///   _subscribe → unsubscribe the old channel, then subscribe a fresh one;
///   dispose    → realtimeResumed.removeListener(_subscribe);
final ValueNotifier<int> realtimeResumed = ValueNotifier<int>(0);
