import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/features/reach/reach_button.dart';

/// The landing screen: how your partner is, right now — plus the Reach button
/// and quick ways into the rest of the app.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _picker = ImagePicker();
  bool _uploading = false;
  bool _promptedLocation = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initLocation());
  }

  Future<void> _initLocation() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final mine = await PresenceService.fetchMine(couple.id);
    final mode = mine?.locationSharingMode ?? 'off';
    if (mode == 'off') {
      if (!_promptedLocation && mounted) {
        _promptedLocation = true;
        await _locationOnboarding();
      }
    } else {
      // Refresh our shared location on open (foreground only).
      await LocationService.shareOnce(couple.id, mode);
    }
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
          'Share your location with $partnerName so you always feel close — '
          "they'll share theirs with you too. You can change or turn this off "
          'any time in Settings.',
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
              child: const Text('Precise')),
        ],
      ),
    );
    if (mode == null) return;
    if (mode == 'off') {
      await PresenceService.setSharingMode(couple.id, 'off');
    } else {
      await LocationService.shareOnce(couple.id, mode);
    }
  }

  Future<void> _shareSnap() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    final x = await _picker.pickImage(
        source: ImageSource.camera, imageQuality: 70, maxWidth: 1000);
    if (x == null) return;
    setState(() => _uploading = true);
    try {
      final uid = SupabaseService.currentUserId!;
      final path =
          '${couple.id}/checkins/${uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await SupabaseService.client.storage
          .from('couple_media')
          .upload(path, File(x.path));
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
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
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
