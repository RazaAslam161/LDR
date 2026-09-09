import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/root_scaffold_key.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/realtime/presence_route_observer.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/ui/mood.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/animated_mood.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/core/widgets/gravity_float.dart';
import 'package:miles/core/widgets/partner_bust.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/core/widgets/screen_entrance.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/core/widgets/wordmark.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/chat/widgets/media_viewer.dart';
import 'package:miles/features/cycle/partner_cycle_card.dart';
import 'package:miles/features/home/partner_location_card.dart';
import 'package:miles/features/reach/reach_button.dart';
import 'package:miles/features/unlink/scene/scene_state.dart' show PuppetVariant, puppetVariantOf;

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

  /// Why this user's own sharing is producing nothing. Sharing 'off' reports
  /// [LocationBlock.none] — the notice is only for the contradiction, where the
  /// mode says sharing and the handset says no.
  LocationBlock _block = LocationBlock.none;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLocationUpdates());
  }

  /// Whether location may be pushed right now.
  ///
  /// Separate from [_locationTimer] because cancelling a timer does not stop a
  /// [_startLocationUpdates] that is currently suspended on one of its own
  /// awaits — and that call goes on to install a NEW timer after the pause has
  /// already been handled. `mounted` does not help: a backgrounded screen is
  /// still mounted, so the ticks kept firing and the app kept pushing GPS
  /// after telling the user it only shares "while the app is open".
  bool _locationActive = false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationActive = false;
    _locationTimer?.cancel();
    _locationTimer = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startLocationUpdates();
    } else {
      // Foreground-only: stop pushing location the moment we leave the app.
      _locationActive = false;
      _locationTimer?.cancel();
      _locationTimer = null;
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
    _locationActive = true;

    // Installed BEFORE the first await, so a background landing during the
    // two calls below always has a timer to cancel and a flag to lower.
    _locationTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!mounted || !_locationActive) return;
      _noteBlock(await LocationService.shareCurrent(couple.id));
      await _refreshMyCoords();
    });

    await _refreshMyCoords();
    if (!mounted || !_locationActive) return;
    // One immediate push so the partner sees a fresh position without waiting.
    _noteBlock(await LocationService.shareCurrent(couple.id));
  }

  /// [shareCurrent] already read the saved mode and the OS state to decide
  /// whether it could send, so its verdict is free — asking again here would
  /// mean a second presence fetch every 15 seconds for every user.
  void _noteBlock(LocationBlock block) {
    if (mounted && block != _block) setState(() => _block = block);
  }

  /// Tapping the notice. The repair depends on what is missing, so the service
  /// decides: re-ask, or open the system page that is the only way back.
  Future<void> _fixLocation() async {
    final block = await LocationService.resolve(context);
    _noteBlock(block);
    final couple = ref.read(currentCoupleProvider);
    if (block == LocationBlock.none && couple != null) {
      _noteBlock(await LocationService.shareCurrent(couple.id));
    }
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
    },);
    if (file == null) return;
    if (!mounted) return;
    setState(() => _uploading = true);
    try {
      final path =
          '${couple.id}/checkins/${uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await SupabaseService.client.storage
          .from('couple_media')
          .upload(path, file);
      // The PATH, not a URL. couple_media is private now; whoever renders it
      // signs it. A public URL stored here outlived the snap by forever.
      await PresenceService.setCheckinPhoto(couple.id, path);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Snap shared 📸')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not share the snap.')),);
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
        // Home is the one screen that may wish: while it is on screen, a
        // single shooting star crosses the ember field per ambient loop.
        // Renders nothing — but it must NOT live inside the ListView: a list
        // destroys the elements of children scrolled past its cache extent,
        // so the marker would quietly release its claim (and the wishes with
        // it) the moment someone scrolled down, then re-claim on the way
        // back. The screen's presence is what grants the wish, not the
        // scroll position.
        child: Stack(
          children: [
            const EmberBackgroundWishes(),
            SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              // One coordinated entrance for the whole page — the auth flow's
              // stagger, as a single scrollable child.
              ScreenEntrance(children: [
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
                  moodArt: moodByKey(ref.watch(partnerMoodProvider))?.artName,
                  uploading: _uploading,
                  onShareSnap: _shareSnap,
                ),
                const SizedBox(height: 16),
                if (_block != LocationBlock.none) ...[
                  _LocationBlockedNotice(block: _block, onFix: _fixLocation),
                  const SizedBox(height: 16),
                ],
                PartnerLocationCard(
                  partner: presence,
                  partnerName: partner.displayName,
                  coupleId: couple.id,
                  partnerProfile: partner,
                  myTimezone: ref.watch(sessionProvider).profile?.timezone,
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
              ],),
            ],
          ),
        ),
          ],
        ),
      ),
    );
  }
}

/// Sharing is on and nothing is being sent. Shown on Home rather than only in
/// Settings, because the state is invisible from the inside: the map on this
/// screen is the PARTNER's, so a user whose own permission is missing sees a
/// perfectly normal dashboard while their partner sees nothing at all.
class _LocationBlockedNotice extends StatelessWidget {
  const _LocationBlockedNotice({required this.block, required this.onFix});

  final LocationBlock block;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final (String text, String action) = switch (block) {
      LocationBlock.serviceDisabled => (
          "Location sharing is on, but your phone's location is switched off, "
              'so your partner sees nothing.',
          'Turn it on',
        ),
      LocationBlock.deniedForever => (
          'Location sharing is on, but this app is not allowed to read your '
              'location, so your partner sees nothing.',
          'Allow it',
        ),
      LocationBlock.denied || LocationBlock.none => (
          "Location sharing is on, but you haven't allowed location yet, so "
              'your partner sees nothing.',
          'Allow it',
        ),
    };

    return SurfacePanel(
      color: MilesColors.tint(MilesColors.ember, 0.12),
      borderColor: MilesColors.ember,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_disabled,
                  color: MilesColors.ember, size: 20,),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text,
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 13, height: 1.4,),),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onFix,
              child: Text(action,
                  style: const TextStyle(color: MilesColors.gilt),),
            ),
          ),
        ],
      ),
    );
  }
}

class _PartnerStatusCard extends StatelessWidget {
  const _PartnerStatusCard({
    required this.partner,
    required this.presence,
    required this.moodArt,
    required this.uploading,
    required this.onShareSnap,
  });

  final Profile partner;
  final Presence? presence;

  /// Their mood's art name — the card's face wears it, same as the AppBar's.
  /// (`mood` is already the MoodData the card's own chip reads.)
  final String? moodArt;
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

    // GravityFloat is Home's one ambient element (the avatar's BreathingGlow
    // is presence signal, not decoration — together they are the "one or
    // two" the motion contract allows). Nothing else on this screen floats.
    // TiltParallax is not a third: it moves only when the PHONE moves, which
    // is the hand's motion being answered, not the interface animating.
    return TiltParallax(
      child: GravityFloat(
      child: SurfacePanel(
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
                    name: partner.displayName,
                    variant: puppetVariantOf(partner.gender),
                    mood: moodArt,
                    online: online,),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => context.push('/app/partner'),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(partner.displayName,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    Theme.of(context).textTheme.headlineSmall,),
                          ),
                          if (mood != null) ...[
                            const SizedBox(width: 6),
                            AnimatedMood(mood: mood, size: 20),
                          ],
                        ],
                      ),
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
                          // The hour, not the age — chat's AppBar carries the
                          // age. Off app_last_active_at rather than the
                          // `last_seen` column this used to read, which moves
                          // only on an online claim and so printed the wrong
                          // moment. See Presence.lastSeenClock.
                          online
                              ? 'Online'
                              : presence?.lastSeenClock() ?? 'Offline',
                          style: const TextStyle(
                              color: MilesColors.taupe, fontSize: 12,),
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
                icon: Icons.favorite_outline, text: 'Feeling ${mood.label}',),
          ],
          // isKnownRoom, not `!= null`: a build-73 partner still publishes
          // 'Vault', 'Disguise', 'Export' — this line is where that word
          // reached the other phone's eyes.
          if (online && isKnownRoom(presence?.currentScreen)) ...[
            const SizedBox(height: 8),
            _InfoRow(
                icon: Icons.smartphone_outlined,
                text: 'In ${presence!.currentScreen}',),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: uploading ? null : onShareSnap,
            icon: uploading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),)
                : const Icon(Icons.camera_alt_outlined, size: 18),
            label: const Text('Share a snap'),
          ),
        ],
      ),
    ),
    ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.name,
    required this.variant,
    this.mood,
    this.photoUrl,
    this.online = false,
  });
  final String name;
  final String? photoUrl;

  /// Their mood's art name, or null for the neutral face.
  final String? mood;

  /// Which bust stands in when there is no check-in photo.
  final PuppetVariant variant;

  /// Drains the colour out of the figure while they are away — the same
  /// "another room" reading the AppBar mark uses.
  final bool online;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '🤍';
    final url = photoUrl;
    // Precedence: their real face, then their figure, then a letter. A
    // check-in photo is a picture they chose to send; replacing that with a
    // rendered stand-in would be taking a feature away to add one. The figure
    // takes the place of the letter, which is what the circle shows the rest
    // of the time.
    //
    // No clock is passed: the BreathingGlow around this circle is already the
    // breath, and a second one inside it would beat against the first.
    final face = PresenceCharacter(
      variant: variant,
      size: 64,
      mood: mood,
      here: online,
      fallback: Center(
        child: Text(initial,
            style: const TextStyle(
                color: MilesColors.cream50, fontSize: 24,),),
      ),
    );
    return EmberPress(
      onTap: url == null
          ? null
          : () => MediaViewer.openStored(context, chatBucket, url,
              heroTag: 'snap-$url',),
      child: ClipOval(
        child: Container(
          width: 64,
          height: 64,
          color: MilesColors.surface2,
          child: url == null
              ? face
              : Hero(
                  tag: 'snap-$url',
                  child: SignedImage(
                      bucket: chatBucket,
                      value: url,
                      placeholder: face,),),
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
              style: const TextStyle(color: MilesColors.cream50, fontSize: 13),),
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

  /// Why the last read or mint produced nothing.
  ///
  /// Both calls used to be wrapped in an empty catch that cleared the spinner
  /// and bound nothing. A timed-out lookup printed "No live code right
  /// now." over an invite that was still live, and a failed mint returned the
  /// screen to its exact prior state — a button that visibly does nothing, on
  /// the one screen that can still hand the code over. The error has to reach
  /// the person looking at it, the way the sibling code screen already does it.
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final invite = await SupabaseRepository.activePairingInvite();
      if (mounted) {
        setState(() {
          _code = invite?.code;
          _error = null;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[pairing] invite lookup failed for '
          '${SupabaseService.currentUserId}: $e');
      if (mounted) {
        setState(() {
          _error = friendlyAuthError(e);
          _loading = false;
        });
      }
    }
  }

  /// Mint a new one. The old code may have expired while they were away, and
  /// without this the only recovery is leaving the couple entirely.
  Future<void> _newCode() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final invite = await SupabaseRepository.createPairingInvite();
      if (mounted) {
        setState(() {
          _code = invite.code;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[pairing] mint failed for '
          '${SupabaseService.currentUserId}: $e');
      if (mounted) {
        setState(() {
          _error = friendlyAuthError(e);
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final error = _error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          const Text('Waiting for your partner to join…',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.cream50, fontSize: 16),),
          // Claimed only while we are actually holding a code. Unconditional,
          // it sat directly above "No live code right now." whenever the invite
          // had been consumed or had expired — the screen contradicting itself
          // on the one fact the user came here for.
          if (code != null) ...[
            const SizedBox(height: 8),
            const Text('They need this code. It is still live.',
                textAlign: TextAlign.center,
                style: TextStyle(color: MilesColors.taupe, fontSize: 13),),
          ],
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
          ] else if (error == null)
            const Text('No live code right now.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 13),),
          // Under BOTH states, which is the whole point: a lookup that failed
          // must not be reported as "no live code" — we did not learn that, we
          // learned nothing — and a mint that failed while an older code is
          // still on screen must not look like the button did nothing at all.
          if (error != null) ...[
            const SizedBox(height: 16),
            AlertBanner(message: error),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : _newCode,
            child: const Text('Get a new code',
                style: TextStyle(color: MilesColors.emberSoft, fontSize: 13),),
          ),
          // The other half of the both-pressed-Create deadlock. Creating a code
          // makes a couple of one, and from the next relaunch this screen was
          // the whole app: the redeem field lives on '/couple', which the router
          // swept away the moment a couple existed. Whoever gives way taps this;
          // redeem_pairing_invite moves them onto their partner's couple and
          // retires the one they were holding.
          TextButton(
            onPressed: _loading ? null : () => context.go('/couple'),
            // A real target rather than 13px of text, for the same reason the
            // couple page's copy of this hatch is one: it is the only way out.
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: MilesColors.taupe,
            ),
            child: const Text('They already have a code? Enter it instead',
                textAlign: TextAlign.center,),
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
            style: const TextStyle(color: MilesColors.taupe),),
      );
}
