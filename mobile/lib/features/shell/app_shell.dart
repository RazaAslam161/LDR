import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/ads/banner_ad_slot.dart';
import 'package:miles/core/providers.dart';
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

class _AppShellState extends ConsumerState<AppShell> {
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribeReach());
  }

  void _subscribeReach() {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
  }

  void _onReach(ReachEvent e) {
    final uid = SupabaseService.currentUserId;
    if (e.isMine(uid) || !e.isActive || _shownReach.contains(e.id)) return;
    _shownReach.add(e.id);
    if (!mounted) return;
    final partnerName =
        ref.read(sessionProvider).partner?.displayName ?? 'Your partner';
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            ReachOverlayScreen(partnerName: partnerName, eventId: e.id),
      ),
    );
  }

  @override
  void dispose() {
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
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(child: screens[selected]),
          if (showAd) const BannerAdSlot(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (i) =>
            ref.read(shellTabProvider.notifier).state = i,
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
            label: 'Countdown',
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
