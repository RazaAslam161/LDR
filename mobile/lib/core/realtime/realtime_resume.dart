import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';

/// Ticks whenever the realtime socket (re)connects. EVERY per-screen realtime
/// subscription listens to this and re-subscribes its channel, so sync survives
/// Android doze / network drops / backgrounding everywhere — not just the
/// always-on channels.
///
/// Usage in a State:
///   initState  → realtimeResumed.addListener(_subscribe);
///   _subscribe → unsubscribe the old channel, then subscribe a fresh one;
///   dispose    → realtimeResumed.removeListener(_subscribe);
final ValueNotifier<int> realtimeResumed = ValueNotifier<int>(0);

bool _hooked = false;

/// Hook the Supabase realtime socket: every time it OPENS (first connect AND
/// every auto-reconnect after a drop), wake all subscriptions to rejoin. The
/// Supabase client reconnects the socket itself on heartbeat loss; this fans
/// that out to the channels, which otherwise sit joined-but-dead. Call once at
/// startup, after SupabaseService.init().
void initRealtimeAutoResume() {
  if (_hooked) return;
  _hooked = true;
  SupabaseService.client.realtime.onOpen(() => realtimeResumed.value++);
}
