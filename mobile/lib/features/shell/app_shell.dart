import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/ads/banner_ad_slot.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/features/breath/breath_sync_screen.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/chat/chat_screen.dart';
import 'package:miles/features/closer/closer_screen.dart';
import 'package:miles/features/countdown/countdown_screen.dart';
import 'package:miles/features/home/home_screen.dart';
import 'package:miles/features/reach/reach_overlay_screen.dart';
import 'package:miles/features/reach/reach_repository.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/skybridge/sky_bridge_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Bottom-nav shell. Tab 0 is Home (the landing screen). The Closer tab is only
/// shown to verified adults. An app-wide listener pops the full-screen Reach
/// overlay whenever the partner reaches.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  RealtimeChannel? _reachChannel;
  final Set<String> _shownReach = {};
  CallState _lastCallState = CallState.idle;

  static const List<Widget> _screens = <Widget>[
    HomeScreen(),
    ChatScreen(),
    CountdownScreen(),
    SkyBridgeScreen(),
    BreathSyncScreen(),
    CloserScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pendingReach.addListener(_onPendingReach);
    pendingCall.addListener(_onPendingCall);
    realtimeResumed.addListener(_rearmAlwaysOn);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onReady());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reconnectRealtime();
  }

  /// Realtime sockets die silently during Android doze (no close event), so the
  /// client keeps "connected" and stops delivering reaches/presence until a full
  /// restart. On resume we force a fresh socket + re-subscribe the reach channel
  /// so Reach (and presence/map, which rejoin on the new socket) recover.
  Future<void> _reconnectRealtime() async {
    // Android doze can kill the socket silently; force a clean reconnect. When
    // it re-opens, onOpen → realtimeResumed → _rearmAlwaysOn + every per-screen
    // subscription rejoins. (Re-subscribing synchronously here raced the
    // still-closing socket and left the channels joined-but-dead — the cause of
    // chat not auto-rendering and the online/offline flicker.)
    try {
      await SupabaseService.client.realtime.disconnect();
      await SupabaseService.client.realtime.connect();
    } catch (_) {}
  }

  /// Re-arm the always-on realtime (reach / call / presence) whenever the
  /// socket (re)connects — driven by realtimeResumed (the onOpen fan-out), so
  /// it runs AFTER the socket is open, never against a closing one.
  void _rearmAlwaysOn() {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    _reachChannel?.unsubscribe();
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
    ref.read(callControllerProvider).reconnect();
    ref.read(sessionProvider.notifier).reconnectPresence();
  }

  void _onReady() {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    // Foreground realtime path — works whether or not push is configured.
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
    // Register this device for push now that we're past login + pairing.
    FcmService.registerToken();
    // One-time, dismissible full-screen-alert prompt (Android 14+).
    final partnerName =
        ref.read(sessionProvider).partner?.displayName ?? 'your partner';
    FsiPermission.promptIfNeeded(context, partnerName);
    // A push may have been tapped before the listener attached.
    _onPendingReach();
    _onPendingCall();
    // Let the partner see which screen we're on.
    reportActiveTab(ref);
  }

  void _onReach(ReachEvent e) {
    final uid = SupabaseService.currentUserId;
    if (e.isMine(uid) || !e.isActive) return;
    final partnerName =
        ref.read(sessionProvider).partner?.displayName ?? 'Your partner';
    _showReach(e.id, partnerName);
  }

  /// From a foreground push or a tapped notification (FcmService.pendingReach).
  void _onPendingReach() {
    final tap = pendingReach.value;
    if (tap == null) return;
    pendingReach.value = null;
    final name = tap.fromName.isNotEmpty ? tap.fromName : 'Your partner';
    _showReach(tap.reachId, name);
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

  /// Single entry point for the overlay — de-duped by reach id so the realtime
  /// and push paths never double-show the same Reach.
  void _showReach(String reachId, String partnerName) {
    if (reachId.isNotEmpty && _shownReach.contains(reachId)) return;
    if (reachId.isNotEmpty) _shownReach.add(reachId);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            ReachOverlayScreen(partnerName: partnerName, eventId: reachId),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pendingReach.removeListener(_onPendingReach);
    pendingCall.removeListener(_onPendingCall);
    realtimeResumed.removeListener(_rearmAlwaysOn);
    _reachChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pop the call screen up on an incoming ring or an outgoing call. (For a
    // ChangeNotifierProvider, prev==next is the same instance, so we track the
    // last state ourselves to detect the inactive -> active transition.)
    ref.listen(callControllerProvider, (_, c) {
      final now = c.state;
      bool active(CallState s) =>
          s == CallState.ringing ||
          s == CallState.calling ||
          s == CallState.connected;
      final fire = active(now) && !active(_lastCallState);
      _lastCallState = now;
      if (fire && context.mounted) GoRouter.of(context).push('/call');
    });

    // Only rebuild the shell when these specific flags flip — NOT on every
    // partner presence / mood / typing tick (all of which flow through
    // sessionProvider and were rebuilding the whole tab scaffold + active screen).
    final isAdult =
        ref.watch(sessionProvider.select((s) => s.profile?.isAdult ?? false));
    final isModest =
        ref.watch(sessionProvider.select((s) => s.couple?.modestMode ?? true));
    final index = ref.watch(shellTabProvider);

    final showCloser = isAdult;
    final screens =
        showCloser ? _screens : _screens.sublist(0, _screens.length - 1);
    final selected = index.clamp(0, screens.length - 1);
    final isCloserTab = showCloser && selected == screens.length - 1;
    // Ads only on the secondary feature tabs (Countdown / Sky / Breath).
    final showAd = selected >= 2 && !isCloserTab;

    return Scaffold(
      key: rootScaffoldKey,
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(child: screens[selected]),
          if (showAd) const BannerAdSlot(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (i) {
          ref.read(shellTabProvider.notifier).state = i;
          reportScreen(ref, kTabScreens[i.clamp(0, kTabScreens.length - 1)]);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          const NavigationDestination(
            icon: Icon(Icons.hourglass_top_outlined),
            selectedIcon: Icon(Icons.hourglass_top),
            label: 'Reunion',
          ),
          const NavigationDestination(
            icon: Icon(Icons.dark_mode_outlined),
            selectedIcon: Icon(Icons.dark_mode),
            label: 'Sky',
          ),
          const NavigationDestination(
            icon: Icon(Icons.air_outlined),
            selectedIcon: Icon(Icons.air),
            label: 'Breath',
          ),
          if (showCloser)
            NavigationDestination(
              icon: const Icon(Icons.lock_outline),
              selectedIcon: Icon(
                isModest ? Icons.lock : Icons.lock_open,
                color: const Color(0xFFEF6F58),
              ),
              label: 'Closer',
            ),
        ],
      ),
    );
  }
}
