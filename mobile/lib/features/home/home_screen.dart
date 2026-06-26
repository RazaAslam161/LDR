import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/services/bg_location.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/animated_mood.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/features/chat/media_viewer.dart';
import 'package:miles/features/cycle/partner_cycle_card.dart';
import 'package:miles/features/home/partner_location_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:miles/features/reach/reach_button.dart';

/// The landing screen: how your partner is, right now — plus the Reach button
/// and quick ways into the rest of the app.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  bool _uploading = false;
  String _myMode = 'off';
  double? _myLat;
  double? _myLon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initLocation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Pause the stream when leaving Home (mode persists; resumes on return).
    LocationService.pauseStream();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null || _myMode != 'precise') return;
    if (state == AppLifecycleState.resumed) {
      LocationService.startLiveSharing(couple.id);
    } else {
      LocationService.pauseStream();
    }
  }

  Future<void> _initLocation() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final mine = await PresenceService.fetchMine(couple.id);
    var mode = mine?.locationSharingMode ?? 'off';

    // Auto-enable live sharing on first install (foreground-only, no persistent
    // notification). Stays on until the user turns it off from the Home card.
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('location_auto_init') ?? false)) {
      await prefs.setBool('location_auto_init', true);
      mode = 'precise';
      await PresenceService.setSharingMode(couple.id, 'precise');
    }

    if (mounted) setState(() => _myMode = mode);
    await _refreshMyCoords();
    if (mode == 'precise') {
      await LocationService.startLiveSharing(couple.id);
      await _refreshMyCoords();
      // Periodic background updates (no notification) so the partner still gets
      // movement when the app is closed. Best-effort (OEM battery limits apply).
      await BgLocationService.enable();
    } else if (mode == 'city') {
      await LocationService.shareOnce(couple.id, mode);
    }
  }

  /// My own coords (for the distance readout) — last-known is instant + prompt-free.
  Future<void> _refreshMyCoords() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (pos != null && mounted) {
        setState(() {
          _myLat = pos.latitude;
          _myLon = pos.longitude;
        });
      }
    } catch (_) {}
  }

  Future<void> _stopLive() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    await LocationService.stopLiveSharing(couple.id);
    await BgLocationService.disable();
    if (mounted) setState(() => _myMode = 'off');
  }

  Future<void> _shareSnap() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    // Fast in-app camera (filters + one tap); it pops the baked file back to us.
    final file = await context.push<File?>('/app/rapid-camera', extra: {
      'coupleId': couple.id,
      'myUid': uid,
      'mode': 'checkin',
    });
    if (file == null) return;
    if (!mounted) return;
    setState(() => _uploading = true);
    try {
      final path =
          '${couple.id}/checkins/${uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await SupabaseService.client.storage
          .from('couple_media')
          .upload(path, file);
      final url = SupabaseService.client.storage
          .from('couple_media')
          .getPublicUrl(path);
      await PresenceService.setCheckinPhoto(couple.id, url);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Snap shared 📸')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not share the snap.')));
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    final couple = ref.watch(currentCoupleProvider);
    final partner = ref.watch(partnerProfileProvider);
    final presence = ref.watch(partnerPresenceProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Tethered',
                      style: Theme.of(context).textTheme.headlineLarge),
                  Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu, color: MilesColors.gilt),
                      onPressed: () =>
                          rootScaffoldKey.currentState?.openDrawer(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (couple == null)
                const _Centered('Link with your partner to begin.')
              else if (partner == null)
                const _Centered("Waiting for your partner to join…")
              else ...[
                _PartnerStatusCard(
                  partner: partner,
                  presence: presence,
                  uploading: _uploading,
                  onShareSnap: _shareSnap,
                ),
                const SizedBox(height: 16),
                PartnerLocationCard(
                  partner: presence,
                  partnerName: partner.displayName,
                  myLat: _myLat,
                  myLon: _myLon,
                ),
                if (_myMode == 'precise') ...[
                  const SizedBox(height: 8),
                  _LiveSharingBanner(
                    partnerName: partner.displayName,
                    onStop: _stopLive,
                  ),
                ],
                const PartnerCycleCard(),
                const SizedBox(height: 36),
                Center(
                  child: ReachButton(
                    coupleId: couple.id,
                    partnerName: partner.displayName,
                  ),
                ),
                const SizedBox(height: 36),
                _QuickActions(
                  onMessages: () =>
                      ref.read(shellTabProvider.notifier).state = 1,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PartnerStatusCard extends StatelessWidget {
  const _PartnerStatusCard({
    required this.partner,
    required this.presence,
    required this.uploading,
    required this.onShareSnap,
  });

  final dynamic partner; // Profile
  final Presence? presence;
  final bool uploading;
  final VoidCallback onShareSnap;

  @override
  Widget build(BuildContext context) {
    final mood = moodByKey(presence?.currentMood);
    final theirTime =
        DateFormat('h:mm a').format(TzHelper.nowIn(partner.timezone as String));
    final online = presence?.isOnline ?? false;
    final mode = presence?.locationSharingMode ?? 'off';
    final locationText = (mode != 'off' && presence?.locationLabel != null)
        ? presence!.locationLabel!
        : 'Location sharing off';

    return GlassPanel(
      glow: MilesColors.blush,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BreathingGlow(
                color: online ? MilesColors.sage : MilesColors.blush,
                period: const Duration(seconds: 5),
                child: _Avatar(
                    photoUrl: presence?.checkinPhotoUrl,
                    name: partner.displayName as String),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(partner.displayName as String,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall),
                        ),
                        if (mood != null) ...[
                          const SizedBox(width: 6),
                          AnimatedMood(mood: mood, size: 20),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                online ? MilesColors.sage : MilesColors.faint,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          online
                              ? 'Online'
                              : presence?.lastSeen == null
                                  ? 'Offline'
                                  : 'Last seen ${DateFormat('h:mm a').format(presence!.lastSeen!)}',
                          style: const TextStyle(
                              color: MilesColors.taupe, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _InfoRow(icon: Icons.schedule, text: '$theirTime their time'),
          const SizedBox(height: 8),
          _InfoRow(icon: Icons.place_outlined, text: locationText),
          if (mood != null) ...[
            const SizedBox(height: 8),
            _InfoRow(
                icon: Icons.favorite_outline, text: 'Feeling ${mood.label}'),
          ],
          if (online && presence?.currentScreen != null) ...[
            const SizedBox(height: 8),
            _InfoRow(
                icon: Icons.smartphone_outlined,
                text: 'In ${presence!.currentScreen}'),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: uploading ? null : onShareSnap,
            icon: uploading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.camera_alt_outlined, size: 18),
            label: const Text('Share a snap'),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.photoUrl});
  final String name;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '🤍';
    final url = photoUrl;
    return GestureDetector(
      onTap: url == null
          ? null
          : () => MediaViewer.open(context, url, heroTag: 'snap-$url'),
      child: ClipOval(
        child: Container(
          width: 64,
          height: 64,
          color: MilesColors.surface2,
          child: url == null
              ? Center(
                  child: Text(initial,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 24)))
              : Hero(
                  tag: 'snap-$url',
                  child: NetImage(url,
                      fit: BoxFit.cover,
                      error: Center(
                          child: Text(initial,
                              style: const TextStyle(
                                  color: MilesColors.cream50, fontSize: 24))))),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: MilesColors.gilt),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: MilesColors.cream50, fontSize: 13)),
        ),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onMessages});
  final VoidCallback onMessages;

  @override
  Widget build(BuildContext context) {
    final actions = [
      (Icons.chat_bubble_outline, 'Messages', onMessages),
      (Icons.lock_clock, 'Capsule', () => context.push('/app/capsule')),
      (Icons.touch_app_outlined, 'Touch', () => context.push('/app/touch')),
      (Icons.lock_outline, 'Vault', () => context.push('/app/vault')),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final a in actions)
          GestureDetector(
            onTap: a.$3,
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: MilesColors.surface1,
                    border: Border.all(
                        color: MilesColors.gilt.withValues(alpha: 0.15)),
                  ),
                  child: Icon(a.$1, color: MilesColors.emberSoft),
                ),
                const SizedBox(height: 6),
                Text(a.$2,
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 11)),
              ],
            ),
          ),
      ],
    );
  }
}

/// "📍 Sharing live location with X" indicator + one-tap off switch (privacy:
/// the sharer always sees they're sharing, and can stop instantly).
class _LiveSharingBanner extends StatelessWidget {
  const _LiveSharingBanner({
    required this.partnerName,
    required this.onStop,
  });
  final String partnerName;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: MilesColors.blush.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MilesColors.blush.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.my_location, color: MilesColors.blush, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Sharing live location with $partnerName',
              style: const TextStyle(color: MilesColors.cream50, fontSize: 12),
            ),
          ),
          GestureDetector(
            onTap: onStop,
            child: const Text(
              'Turn off',
              style: TextStyle(
                  color: MilesColors.blush,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(40),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: MilesColors.taupe)),
      );
}
