import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/wordmark.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/animated_mood.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/features/chat/media_viewer.dart';
import 'package:miles/features/cycle/partner_cycle_card.dart';
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
  double? _myLat;
  double? _myLon;
  Timer? _locationTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLocationUpdates());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startLocationUpdates();
    } else {
      // Foreground-only: stop pushing location the moment we leave the app.
      _locationTimer?.cancel();
    }
  }

  /// Simple foreground location sharing: while Home is open and the user's mode
  /// isn't 'off', push the current position now and then every 15s. No live
  /// toggle, no foreground service, no background location. [shareCurrent]
  /// re-reads the saved mode each tick, so changing it in Settings (including to
  /// 'off') is honoured within one tick.
  Future<void> _startLocationUpdates() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    _locationTimer?.cancel();

    await _refreshMyCoords();
    // One immediate push so the partner sees a fresh position without waiting.
    await LocationService.shareCurrent(couple.id);

    _locationTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!mounted) return;
      await LocationService.shareCurrent(couple.id);
      await _refreshMyCoords();
    });
  }

  /// My own coords (for the distance readout) — last-known is instant + prompt-free.
  Future<void> _refreshMyCoords() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      // A stationary phone returns the identical fix every 15s; rebuilding the
      // whole Home list (map polyline included) for it is pure waste.
      if (pos != null &&
          mounted &&
          (pos.latitude != _myLat || pos.longitude != _myLon)) {
        setState(() {
          _myLat = pos.latitude;
          _myLon = pos.longitude;
        });
      }
    } catch (_) {}
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
                  // Flexible, because the trailing controls are fixed-width
                  // and the mark at a large text scale would otherwise overflow
                  // the row outright.
                  const Flexible(child: Wordmark(size: 30)),
                  Row(
                    children: [
                      // Home has no AppBar, but it IS a joinable tab — without
                      // this the one screen a partner is most often on is the
                      // one where they cannot be seen.
                      const PartnerHereAction(),
                      Builder(
                        builder: (ctx) => IconButton(
                          icon: const Icon(Icons.menu, color: MilesColors.gilt),
                          onPressed: () =>
                              rootScaffoldKey.currentState?.openDrawer(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (couple == null)
                const _Centered('Link with your partner to begin.')
              else if (partner == null)
                const _WaitingForPartner()
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
                  coupleId: couple.id,
                  myLat: _myLat,
                  myLon: _myLon,
                ),
                const PartnerCycleCard(),
                const SizedBox(height: 36),
                Center(
                  child: ReachButton(
                    coupleId: couple.id,
                    partnerName: partner.displayName,
                  ),
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

  final Profile partner;
  final Presence? presence;
  final bool uploading;
  final VoidCallback onShareSnap;

  @override
  Widget build(BuildContext context) {
    final mood = moodByKey(presence?.currentMood);
    final theirTime =
        DateFormat('h:mm a').format(TzHelper.nowIn(partner.timezone));
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
                    name: partner.displayName),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(partner.displayName,
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

/// The half-paired state: a couple exists, but nobody else is in it.
///
/// This used to be one line of text and nothing else. The person who created
/// the invite lands here, and if they lost the code — which happens the moment
/// they leave the app to send it — there was no way to see it again, no way to
/// share it again, and no way to undo. The couple existed, so the router would
/// never send them back to the pairing screen either. A dead end that required
/// abandoning the account.
class _WaitingForPartner extends StatefulWidget {
  const _WaitingForPartner();

  @override
  State<_WaitingForPartner> createState() => _WaitingForPartnerState();
}

class _WaitingForPartnerState extends State<_WaitingForPartner> {
  String? _code;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final invite = await SupabaseRepository.activePairingInvite();
      if (mounted) setState(() {
        _code = invite?.code;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Mint a new one. The old code may have expired while they were away, and
  /// without this the only recovery is leaving the couple entirely.
  Future<void> _newCode() async {
    setState(() => _loading = true);
    try {
      final invite = await SupabaseRepository.createPairingInvite();
      if (mounted) setState(() {
        _code = invite.code;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          const Text('Waiting for your partner to join…',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.cream50, fontSize: 16)),
          const SizedBox(height: 8),
          const Text('They need this code. It is still live.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
          const SizedBox(height: 24),
          if (_loading)
            const CircularProgressIndicator(color: MilesColors.ember)
          else if (code != null) ...[
            SelectableText(
              code,
              style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 34,
                letterSpacing: 8,
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy code'),
                ),
              ],
            ),
          ] else
            const Text('No live code right now.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : _newCode,
            child: const Text('Get a new code',
                style: TextStyle(color: MilesColors.emberSoft, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// "📍 Sharing live location with X" indicator + one-tap off switch (privacy:
/// the sharer always sees they're sharing, and can stop instantly).
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
