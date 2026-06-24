import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/ads/banner_ad_slot.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/features/breath/breath_sync_screen.dart';
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
  void _reconnectRealtime() {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    try {
      SupabaseService.client.realtime.disconnect();
    } catch (_) {}
    _reachChannel?.unsubscribe();
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
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
    _reachChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final isAdult = session.profile?.isAdult ?? false;
    final isModest = session.couple?.modestMode ?? true;
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
