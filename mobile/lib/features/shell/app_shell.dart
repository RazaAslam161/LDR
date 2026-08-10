import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/ads/banner_ad_slot.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/router.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/chat/chat_screen.dart';
import 'package:miles/features/closer/closer_screen.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/home/home_screen.dart';
import 'package:miles/features/reach/reach_overlay_screen.dart';
import 'package:miles/features/reach/reach_repository.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/touch_map/touch_map_screen.dart';
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

  // Bottom-nav bodies. The Camera tab (nav index 2) is a push with no body, so
  // it is intentionally absent here. Indices map past it in build().
  static const List<Widget> _screens = <Widget>[
    HomeScreen(),
    ChatScreen(),
    TouchMapScreen(),
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
      // connect() is marked @internal by realtime_client, so a package upgrade
      // may remove it without a breaking-change note and this reconnect would
      // stop compiling — or worse, be "fixed" by deleting it. Kept because the
      // pair is what actually revives the socket after doze, and every feature
      // that reads as broken in the field (presence, receipts, call
      // signalling) rides on that socket. Replacing it needs a two-phone test,
      // not a refactor.
      // ignore: invalid_use_of_internal_member
      await SupabaseService.client.realtime.connect();
    } catch (_) {}
  }

  /// Re-arm the always-on realtime (reach / call / presence) whenever the
  /// socket (re)connects — driven by realtimeResumed (the onOpen fan-out), so
  /// it runs AFTER the socket is open, never against a closing one.
  Future<void> _rearmAlwaysOn() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    // Pattern A: remove the old reach channel (awaited) before re-subscribing so
    // a reconnect never leaves a duplicate-topic 'reach:<id>' channel dead.
    final old = _reachChannel;
    _reachChannel = null;
    if (old != null) {
      try {
        await SupabaseService.client.removeChannel(old);
      } catch (_) {}
    }
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
    ref.read(callControllerProvider).reconnect();
    ref.read(sessionProvider.notifier).reconnectPresence();
  }

  /// Shows the disguise picker the first time only. Deliberately after pairing
  /// rather than at sign-up: before there is a partner there is nothing on the
  /// phone worth disguising, and an icon-change prompt during onboarding reads
  /// as suspicious rather than protective.
  Future<void> _offerDisguiseOnce() async {
    if (await DisguiseService.hasChosen()) return;
    if (!mounted) return;
    await context.push('/app/disguise?onboarding=1');
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
    // Offer the launcher disguise once, after pairing — the point at which the
    // app has something worth hiding. Skipped forever once answered either way.
    _offerDisguiseOnce();
    // A push may have been tapped before the listener attached.
    _onPendingReach();
    _onPendingCall();
    // The shell mounts on '/app', which the observer answers from the selected
    // tab — but that happens before this state exists on a cold start.
    presenceRouteObserver?.publishActiveTab();
    // Granting the OS location permission used to change nothing: the app-level
    // sharing mode stayed 'off' and the partner's Home stayed empty until the
    // user found the second switch in Settings. Runs once, ever.
    final myCouple = ref.read(sessionProvider).couple;
    if (myCouple != null) {
      LocationService.adoptPermissionAsDefault(myCouple.id);
    }
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
    final ch = _reachChannel;
    _reachChannel = null;
    if (ch != null) SupabaseService.client.removeChannel(ch);
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
    // Bottom-nav bodies (Home, Chat, Touch, [Closer]). The Camera tab is a
    // full-screen PUSH inserted at nav index 2 — it has no body, so nav indices
    // map past it.
    final bodies =
        showCloser ? _screens : _screens.sublist(0, _screens.length - 1);
    const cameraTab = 2;
    final destCount = bodies.length + 1; // + the Camera tab
    final selected = index.clamp(0, destCount - 1);
    final bodyIndex = (selected < cameraTab ? selected : selected - 1)
        .clamp(0, bodies.length - 1);
    final isCloserTab = showCloser && selected == destCount - 1;
    final showAd = selected == 3 && !isCloserTab; // ads only on the Touch tab

    return Scaffold(
      key: rootScaffoldKey,
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(child: bodies[bodyIndex]),
          if (showAd) const BannerAdSlot(),
        ],
      ),
      bottomNavigationBar: SurfaceNavBar(
        child: NavigationBar(
          backgroundColor: Colors.transparent,
          selectedIndex: selected,
          onDestinationSelected: (i) {
            if (i == cameraTab) {
              _openCamera(); // a push — keep the current tab selected
              return;
            }
            ref.read(shellTabProvider.notifier).state = i;
            // A tab change is a setState, not a navigation, so nothing else
            // can tell the partner the user has moved rooms.
            presenceRouteObserver?.publishActiveTab();
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
              icon: Icon(Icons.camera_alt_outlined),
              selectedIcon: Icon(Icons.camera_alt),
              label: 'Camera',
            ),
            const NavigationDestination(
              icon: Icon(Icons.touch_app_outlined),
              selectedIcon: Icon(Icons.touch_app),
              label: 'Touch',
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
      ),
    );
  }

  /// Opens the in-app rapid camera (the centre nav button) — a full-screen push
  /// that drops the snap into chat.
  void _openCamera() {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    context.push('/app/rapid-camera', extra: {
      'coupleId': couple.id,
      'myUid': SupabaseService.currentUserId ?? '',
    },);
  }
}
