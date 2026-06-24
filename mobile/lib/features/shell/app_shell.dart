import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/ads/banner_ad_slot.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/features/breath/breath_sync_screen.dart';
import 'package:miles/features/chat/chat_screen.dart';
import 'package:miles/features/closer/closer_screen.dart';
import 'package:miles/features/countdown/countdown_screen.dart';
import 'package:miles/features/reach/reach_screen.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/skybridge/sky_bridge_screen.dart';

/// Bottom-nav shell that hosts the feature tabs.
/// The 5th tab (Closer / intimacy module) is always present — the screen
/// itself handles the modest-mode state and shows the appropriate gate.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  List<Widget> get _screens => const <Widget>[
        ChatScreen(),
        CountdownScreen(),
        SkyBridgeScreen(),
        BreathSyncScreen(),
        ReachScreen(),
        CloserScreen(),
      ];

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final isAdult = session.profile?.isAdult ?? false;
    final isModest = session.couple?.modestMode ?? true;

    // The Closer tab is only visible to verified adults who have opted in.
    // We don't hide it from minors (they're blocked from signing up), but we
    // DO respect modest-mode: the tab is always present, the screen shows the
    // gate when modest mode is on. This keeps the nav count stable.
    final showCloser = isAdult;
    final screens = showCloser
        ? _screens
        : _screens.sublist(0, _screens.length - 1);

    final selected = _index.clamp(0, screens.length - 1);
    // The Closer (intimacy) tab is the last one when present. Ads must never
    // appear there — AdMob forbids ads next to mature content.
    final isCloserTab = showCloser && selected == screens.length - 1;

    return Scaffold(
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(child: screens[selected]),
          // No ad on the Closer (mature) tab, nor on the Chat home screen.
          if (!isCloserTab && selected != 0) const BannerAdSlot(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
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
          const NavigationDestination(
            icon: Icon(Icons.favorite_outline),
            selectedIcon: Icon(Icons.favorite),
            label: 'Reach',
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
