import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/call/call_pip.dart' show CallPip;

/// Answers calls from anywhere in the app, not only from inside the shell.
///
/// Both halves of reaching a call — handing an FCM ring to the controller, and
/// pushing `/call` once the controller goes active — used to live in AppShell,
/// which exists only under `/app/...`. Any redirect that leaves that subtree
/// therefore made the phone unanswerable, and the unlinking ceremony does
/// exactly that for a whole day on both handsets, even though `unlinkAllows`
/// names `/call` as one of the exits it never gates. The gate was honest; the
/// only widget that could act on it had been unmounted.
///
/// Mounted in the root builder beside [CallPip], so it covers every route the
/// shell does and the ones it does not. This is the same hole the cover host closes
/// for a raised cover, reached from the other side: there, no router exists at
/// all; here, the router exists and the shell does not.
class CallRouteBridge extends ConsumerStatefulWidget {
  const CallRouteBridge({super.key});

  @override
  ConsumerState<CallRouteBridge> createState() => _CallRouteBridgeState();
}

class _CallRouteBridgeState extends ConsumerState<CallRouteBridge> {
  /// Per-State, and deliberately not the only guard — the disguise cover swaps
  /// the whole MaterialApp, so this restarts at idle while the router still
  /// holds /call. [pushCallRoute] asks the router what is actually on top,
  /// which no remount can lie about.
  CallState _lastCallState = CallState.idle;

  @override
  void initState() {
    super.initState();
    pendingCall.addListener(_onPendingCall);
    // It may have arrived before this was built — a cold start woken by a ring.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPendingCall());
  }

  @override
  void dispose() {
    pendingCall.removeListener(_onPendingCall);
    super.dispose();
  }

  /// An incoming call delivered by FCM (full-screen ring / tapped notification /
  /// cold start). Hand it to the CallController to fetch the offer + ring.
  void _onPendingCall() {
    final tap = pendingCall.value;
    if (tap == null) return;
    pendingCall.value = null;
    ref
        .read(callControllerProvider)
        .handlePendingCall(tap.callId, tap.fromName, tap.video);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(callControllerProvider, (_, c) {
      final now = c.state;
      bool active(CallState s) =>
          s == CallState.ringing ||
          s == CallState.calling ||
          s == CallState.connected;
      final fire = active(now) && !active(_lastCallState);
      _lastCallState = now;
      // The router rather than this context: the root builder sits above the
      // routed subtree, so GoRouter.of(context) is not the navigator to push.
      if (fire) pushCallRoute(ref.read(routerProvider));
    });
    return const SizedBox.shrink();
  }
}
