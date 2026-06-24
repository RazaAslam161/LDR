import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/features/home/partner_location_card.dart';
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
  bool _promptedLocation = false;
  String _myMode = 'off';
  bool _alwaysOn = false;
  double? _myLat;
  double? _myLon;

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Opt in/out of always-on (background) sharing. Enabling needs "Allow all the
  /// time" — if it isn't granted we open app settings and ask them to return.
  Future<void> _setAlwaysOn(bool value) async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    if (!value) {
      await LocationService.setAlwaysOnPref(value: false);
      await LocationService.startLiveSharing(couple.id); // back to foreground-only
      if (mounted) setState(() => _alwaysOn = false);
      return;
    }
    final perm = await LocationService.ensurePermission();
    if (LocationService.blocked(perm)) return;
    if (!await LocationService.hasBackgroundPermission()) {
      _snack("Set Location to 'Allow all the time', then turn this on again.");
      await Geolocator.openAppSettings();
      return;
    }
    await LocationService.setAlwaysOnPref(value: true);
    await LocationService.startLiveSharing(couple.id); // restart with bg service
    if (mounted) setState(() => _alwaysOn = true);
  }

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
    final mode = mine?.locationSharingMode ?? 'off';
    final always = await LocationService.isAlwaysOn();
    if (mounted) {
      setState(() {
        _myMode = mode;
        _alwaysOn = always;
      });
    }
    await _refreshMyCoords();
    if (mode == 'off') {
      if (!_promptedLocation && mounted) {
        _promptedLocation = true;
        await _locationOnboarding();
      }
    } else if (mode == 'precise') {
      await LocationService.startLiveSharing(couple.id);
      await _refreshMyCoords();
    } else {
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

  Future<void> _startLive() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final ok = await LocationService.startLiveSharing(couple.id);
    if (mounted) setState(() => _myMode = ok ? 'precise' : 'off');
    await _refreshMyCoords();
  }

  Future<void> _stopLive() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    await LocationService.stopLiveSharing(couple.id);
    if (mounted) setState(() => _myMode = 'off');
  }

  Future<void> _locationOnboarding() async {
    final partnerName =
        ref.read(partnerProfileProvider)?.displayName ?? 'your partner';
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('See where each other is 💕'),
        content: Text(
          'Share your live location with $partnerName? You\'ll both see each '
          'other on the map and always know you\'re close. You can turn this '
          'off anytime.',
          style: const TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'off'),
              child: const Text('Not now')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'city'),
              child: const Text('City only')),
          FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: MilesColors.blush),
              onPressed: () => Navigator.pop(ctx, 'precise'),
              child: const Text('Share live')),
        ],
      ),
    );
    if (mode == null) return;
    if (mode == 'off') {
      await PresenceService.setSharingMode(couple.id, 'off');
    } else if (mode == 'precise') {
      await _startLive();
    } else {
      await LocationService.shareOnce(couple.id, mode);
    }
  }

  Future<void> _shareSnap() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final file = await PhotoPickerService.pickFromSheet(context);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final uid = SupabaseService.currentUserId!;
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Snap shared 📸')));
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
                      onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
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
                    alwaysOn: _alwaysOn,
                    onAlwaysOnChanged: _setAlwaysOn,
                    onStop: _stopLive,
                  ),
                ],
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
                              style:
                                  Theme.of(context).textTheme.headlineSmall),
                        ),
                        if (mood != null) ...[
                          const SizedBox(width: 6),
                          Text(mood.emoji,
                              style: const TextStyle(fontSize: 15)),
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
                            color: online ? MilesColors.sage : MilesColors.faint,
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
            _InfoRow(icon: Icons.favorite_outline, text: 'Feeling ${mood.label}'),
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
    return ClipOval(
      child: Container(
        width: 64,
        height: 64,
        color: MilesColors.surface2,
        child: photoUrl == null
            ? Center(
                child: Text(initial,
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 24)))
            : Image.network(photoUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                    child: Text(initial,
                        style: const TextStyle(
                            color: MilesColors.cream50, fontSize: 24)))),
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
    required this.alwaysOn,
    required this.onAlwaysOnChanged,
    required this.onStop,
  });
  final String partnerName;
  final bool alwaysOn;
  final ValueChanged<bool> onAlwaysOnChanged;
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
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.my_location, color: MilesColors.blush, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sharing live location with $partnerName',
                  style:
                      const TextStyle(color: MilesColors.cream50, fontSize: 12),
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
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Keep sharing when the app is closed',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 11),
                ),
              ),
              Switch(
                value: alwaysOn,
                onChanged: onAlwaysOnChanged,
                activeThumbColor: MilesColors.blush,
              ),
            ],
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
