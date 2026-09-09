import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/sound/content_player.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/countdown_digits.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/capsule/capsule_repository.dart';
import 'package:miles/features/capsule/proximity_service.dart';

class CapsuleDetailScreen extends ConsumerStatefulWidget {
  const CapsuleDetailScreen({required this.capsule, super.key});
  final Capsule capsule;

  @override
  ConsumerState<CapsuleDetailScreen> createState() =>
      _CapsuleDetailScreenState();
}

class _CapsuleDetailScreenState extends ConsumerState<CapsuleDetailScreen>
    with WidgetsBindingObserver {
  late Capsule _capsule = widget.capsule;
  Map<CapsuleItemType, int> _summary = const {};
  List<CapsuleItem> _items = const [];
  bool _loading = true;
  bool _opening = false;
  bool _revealed = false;
  String? _error;
  String? _itemsError;

  ProximityService? _prox;
  ProximityStatus? _proxStatus;
  bool _checking = false;

  /// True only between "we opened the settings app for them" and the resume
  /// that follows it. Scoped that tightly on purpose: Android's own permission
  /// dialog pauses and resumes the app, so a re-check on EVERY resume would
  /// re-request permission, be denied, resume, and re-request — a prompt loop
  /// with no way out of the screen.
  bool _sentToSettings = false;

  final AudioPlayer _player = newContentPlayer();
  ManagedSubscription? _channel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel = ManagedSubscription.start(
        () => CapsuleRepository.subscribe(_capsule.coupleId, _reload),);
    if (_capsule.isUnlocked) {
      _revealAlreadyOpen();
    } else {
      _loadSummary();
    }
  }

  Future<void> _loadSummary() async {
    try {
      _summary = await CapsuleRepository.sealSummary(_capsule.id);
      _itemsError = null;
    } catch (e) {
      // _SealedView renders summary.values.fold(...) as "N memories sealed
      // inside", so a swallowed failure told them the capsule holds nothing.
      _itemsError = friendlyAuthError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _revealAlreadyOpen() async {
    MilesSound.cue(Cue.chime);
    await _loadItems();
    if (mounted) {
      setState(() {
        _loading = false;
        _revealed = true;
      });
    }
  }

  /// Reads the sealed contents. Never silent: _RevealedView renders "This
  /// capsule was empty. Next time, fill it up 💫" for an empty list, which is
  /// the cruellest possible thing to show after months of filling it.
  Future<void> _loadItems() async {
    try {
      _items = await CapsuleRepository.items(_capsule.id);
      _itemsError = null;
    } catch (e) {
      _itemsError = friendlyAuthError(e);
    }
  }

  /// Called when the capsule row changes (e.g. the partner opens it).
  Future<void> _reload() async {
    try {
      final all = await CapsuleRepository.list(_capsule.coupleId);
      Capsule? found;
      for (final c in all) {
        if (c.id == _capsule.id) found = c;
      }
      if (found == null || !mounted) return;
      _capsule = found;
      if (_capsule.isUnlocked && !_revealed && !_opening) {
        unawaited(_runCeremony());
      } else {
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _startProximity() async {
    // The error card's "Try again" lands here too, so the previous service —
    // its 4s timer and its broadcast channel — has to go before a second one
    // starts, or every retry leaves another one pinging behind it.
    _prox?.stop();
    setState(() {
      _checking = true;
      _proxStatus = null;
    });
    _prox = ProximityService();
    await _prox!.start(
      coupleId: _capsule.coupleId,
      onUpdate: (s) {
        if (mounted) setState(() => _proxStatus = s);
      },
    );
  }

  /// Coming back from the settings app is the moment the answer changed, so it
  /// is the moment to ask again. [ProximityService.start] takes an early exit
  /// when location is off or unpermitted — no 4s timer is armed, that instance
  /// never speaks again — so without this the user flips the toggle, returns,
  /// and the card still reads "Location is off" until the screen is rebuilt.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_sentToSettings) return;
    _sentToSettings = false;
    if (!mounted || _revealed || _opening || !_checking) return;
    unawaited(_startProximity());
  }

  /// Which page repairs this depends on which half of `permissionBlocked` is
  /// true, and they are not the same screen: with location services off
  /// device-wide, the app's own settings page holds no toggle that fixes it.
  /// Sending both cases to `openAppSettings` — as the card did — left half of
  /// them staring at a page that could not help.
  Future<void> _openLocationSettings({required bool serviceOff}) async {
    _sentToSettings = true;
    final opened = serviceOff
        ? await Geolocator.openLocationSettings()
        : await Geolocator.openAppSettings();
    if (opened) return;
    if (!mounted) return;
    // A button that silently does nothing is worse than no button. This fails
    // on handsets whose OEM removed the settings activity we ask for.
    _sentToSettings = false;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(serviceOff
          ? "This phone wouldn't open its location settings. Turn Location on "
              'from the notification shade, then tap Check again.'
          : "This phone wouldn't open Miles' settings. Allow Location for "
              'Miles from Settings › Apps, then tap Check again.'),
    ),);
  }

  bool get _canOpen {
    if (_capsule.unlockMode == CapsuleUnlockMode.date) {
      return _capsule.dateConditionMet;
    }
    final near = _proxStatus?.withinRange ?? false;
    if (_capsule.unlockMode == CapsuleUnlockMode.proximity) return near;
    return near && _capsule.dateConditionMet; // both
  }

  Future<void> _attemptOpen() async {
    setState(() => _error = null);
    try {
      _capsule = await CapsuleRepository.unlock(_capsule.id);
      await _runCeremony();
    } catch (e) {
      final s = e.toString();
      setState(() => _error =
          s.contains('too_early') ? "It's not time yet." : 'Could not open it.',);
    }
  }

  Future<void> _runCeremony() async {
    _prox?.stop();
    MilesSound.cue(Cue.open);
    setState(() {
      _opening = true;
      _checking = false;
    });
    // Let the ceremony breathe, then reveal.
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    await _loadItems();
    if (mounted) {
      setState(() {
        _opening = false;
        _revealed = true;
      });
    }
  }

  Future<void> _playVoice(String path) async {
    try {
      final url = await CapsuleRepository.signedUrl(path);
      await _player.setUrl(url);
      await _player.play();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not play that memo.')),);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel?.dispose();
    _prox?.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(_capsule.title),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _opening
                ? _CeremonyView(title: _capsule.title)
                : _revealed
                    ? _RevealedView(
                        items: _items,
                        loadError: _itemsError,
                        onRetry: () async {
                          await _loadItems();
                          if (mounted) setState(() {});
                        },
                        onPlayVoice: _playVoice,
                      )
                    : _SealedView(
                        capsule: _capsule,
                        summary: _summary,
                        summaryError: _itemsError,
                        checking: _checking,
                        proxStatus: _proxStatus,
                        canOpen: _canOpen,
                        error: _error,
                        onAdd: () async {
                          await context.push('/app/capsule/fill',
                              extra: _capsule,);
                          unawaited(_loadSummary());
                        },
                        onCheckProximity: _startProximity,
                        onOpenSettings: _openLocationSettings,
                        onOpen: _attemptOpen,
                      ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SEALED
// ─────────────────────────────────────────────────────────────────────────────
class _SealedView extends StatelessWidget {
  const _SealedView({
    required this.capsule,
    required this.summary,
    required this.summaryError,
    required this.checking,
    required this.proxStatus,
    required this.canOpen,
    required this.error,
    required this.onAdd,
    required this.onCheckProximity,
    required this.onOpenSettings,
    required this.onOpen,
  });

  final Capsule capsule;
  final Map<CapsuleItemType, int> summary;
  final String? summaryError;
  final bool checking;
  final ProximityStatus? proxStatus;
  final bool canOpen;
  final String? error;
  final VoidCallback onAdd;
  final VoidCallback onCheckProximity;
  final void Function({required bool serviceOff}) onOpenSettings;
  final VoidCallback onOpen;

  int get _total => summary.values.fold(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        Center(
          child: BreathingGlow(
            child: Container(
              width: 150,
              height: 150,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  MilesColors.surface2,
                  MilesColors.nightDeep,
                ],),
              ),
              child: const Center(
                  child: Text('🔒', style: TextStyle(fontSize: 52)),),
            ),
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: Text(
              summaryError == null
                  ? '$_total memories sealed inside'
                  : "Couldn't count what's inside",
              style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,),),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(_anticipation(capsule),
              textAlign: TextAlign.center,
              style: const TextStyle(color: MilesColors.taupe, height: 1.5),),
        ),
        // CountTick: the wait, counted — digits turn as the day approaches.
        if (capsule.unlockMode == CapsuleUnlockMode.date &&
            capsule.unlockDate != null &&
            capsule.unlockDate!.isAfter(DateTime.now())) ...[
          const SizedBox(height: 10),
          Center(child: CountdownDigits(until: capsule.unlockDate!)),
        ],
        const SizedBox(height: 28),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('Add to the capsule'),
        ),
        const SizedBox(height: 28),
        _UnlockSection(
          capsule: capsule,
          checking: checking,
          proxStatus: proxStatus,
          canOpen: canOpen,
          onCheckProximity: onCheckProximity,
          onOpenSettings: onOpenSettings,
          onOpen: onOpen,
        ),
        if (error != null) ...[
          const SizedBox(height: 14),
          Center(
              child: Text(error!,
                  style: const TextStyle(color: MilesColors.blush),),),
        ],
      ],
    );
  }

  String _anticipation(Capsule c) {
    switch (c.unlockMode) {
      case CapsuleUnlockMode.proximity:
        return "Sealed until you're together again.";
      case CapsuleUnlockMode.date:
        final d = c.unlockDate;
        return d == null
            ? 'Sealed until the day.'
            : 'Sealed until ${DateFormat('MMMM d, y').format(d)}.';
      case CapsuleUnlockMode.both:
        return "Sealed until you're together, on the day.";
    }
  }
}

class _UnlockSection extends StatelessWidget {
  const _UnlockSection({
    required this.capsule,
    required this.checking,
    required this.proxStatus,
    required this.canOpen,
    required this.onCheckProximity,
    required this.onOpenSettings,
    required this.onOpen,
  });

  final Capsule capsule;
  final bool checking;
  final ProximityStatus? proxStatus;
  final bool canOpen;
  final VoidCallback onCheckProximity;
  final void Function({required bool serviceOff}) onOpenSettings;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    // Pure date mode.
    if (capsule.unlockMode == CapsuleUnlockMode.date) {
      if (capsule.dateConditionMet) return _openButton();
      return _sealedHint(
          'Come back on ${DateFormat('MMMM d').format(capsule.unlockDate!)} — '
          'it opens itself.');
    }

    // Proximity is involved (proximity or both).
    final children = <Widget>[];

    if (capsule.unlockMode == CapsuleUnlockMode.both) {
      children.add(_conditionRow(
        capsule.dateConditionMet,
        capsule.dateConditionMet
            ? 'The day has come'
            : 'Opens from ${DateFormat('MMM d').format(capsule.unlockDate!)}',
      ),);
      children.add(const SizedBox(height: 8));
    }

    if (!checking) {
      children.add(FilledButton.icon(
        onPressed: onCheckProximity,
        icon: const Icon(Icons.my_location),
        label: const Text('Are we together? Check'),
      ),);
    } else {
      children.add(_proximityStatus(context));
    }

    if (canOpen) {
      children
        ..add(const SizedBox(height: 12))
        ..add(_openButton());
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _proximityStatus(BuildContext context) {
    final s = proxStatus;
    if (s == null) {
      return _hintCard('Looking for your location…');
    }
    if (s.permissionBlocked) {
      // `permissionBlocked` is two different failures wearing one card, and
      // they are repaired on two different screens — see [onOpenSettings].
      // Saying "Location is off" to someone whose location is ON but who never
      // granted the app permission sent them hunting for a toggle that was
      // already where they left it.
      final serviceOff = !s.serviceEnabled;
      final extra = capsule.unlockMode == CapsuleUnlockMode.both
          ? ' It can still open on its date.'
          : '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hintCard(
            serviceOff
                ? 'Location is off on this phone. A "when you\'re together" '
                    "capsule needs it to know you've reunited.$extra"
                : "Miles doesn't have permission to use this phone's location, "
                    "so it can't tell when you've reunited.$extra",
            icon: Icons.location_off,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => onOpenSettings(serviceOff: serviceOff),
            child: Text(serviceOff ? 'Turn on location' : 'Open app settings'),
          ),
          const SizedBox(height: 4),
          // The one control that makes this card not a dead end. The service
          // takes an early exit on this branch and arms no timer, so nothing
          // re-checks on its own: turn location on, come back, and the card
          // still said "Location is off" until the screen was rebuilt. This
          // starts a NEW service, which asks the platform again from scratch.
          TextButton.icon(
            onPressed: onCheckProximity,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Check again'),
          ),
        ],
      );
    }
    if (s.withinRange) {
      return _hintCard("You're together 💞  Open it.",
          icon: Icons.favorite, color: MilesColors.sage,);
    }
    // Before the distance and before the wait: a failed check on THIS handset
    // is not news about the partner. The service had written the cause into
    // `error` since the audit and nothing read it, so every unknown throw —
    // a platform exception, a fix that never arrived — fell through to
    // "waiting for your partner" and blamed them for this phone's fault.
    if (s.error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hintCard(
            capsule.unlockMode == CapsuleUnlockMode.both
                ? '${s.error} It can still open on its date.'
                : s.error!,
            icon: Icons.error_outline,
            color: MilesColors.blush,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: onCheckProximity,
            child: const Text('Try again'),
          ),
        ],
      );
    }
    if (s.partnerSeen && s.distanceMeters != null) {
      return _hintCard('So close — about ${s.distanceMeters!.round()}m apart.',
          icon: Icons.near_me,);
    }
    return _hintCard(
        'Waiting for your partner to open this on their phone too…',
        icon: Icons.hourglass_top,);
  }

  Widget _conditionRow(bool met, String label) {
    return Row(
      children: [
        Icon(met ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18, color: met ? MilesColors.sage : MilesColors.faint,),
        const SizedBox(width: 8),
        Text(label,
            style: TextStyle(
                color: met ? MilesColors.cream50 : MilesColors.taupe,
                fontSize: 13,),),
      ],
    );
  }

  Widget _openButton() => FilledButton(
        onPressed: onOpen,
        style: FilledButton.styleFrom(backgroundColor: MilesColors.blush),
        child: const Text('✨  Open the capsule'),
      );

  Widget _sealedHint(String text) => _hintCard(text, icon: Icons.lock_clock);

  Widget _hintCard(String text,
      {IconData icon = Icons.info_outline, Color color = MilesColors.taupe,}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: color, height: 1.4, fontSize: 13),),),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CEREMONY
// ─────────────────────────────────────────────────────────────────────────────
class _CeremonyView extends StatelessWidget {
  const _CeremonyView({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The ceremony orb leans with the phone — the one place in the app
          // where a held object should feel like it has weight.
          TiltParallax(
            depth: 6,
            child: BreathingGlow(
            color: MilesColors.emberSoft,
            period: const Duration(milliseconds: 1600),
            child: Container(
              width: 170,
              height: 170,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  MilesColors.emberSoft,
                  MilesColors.blush,
                  MilesColors.nightDeep,
                ],),
              ),
              child: const Center(
                  child: Text('💝', style: TextStyle(fontSize: 64)),),
            ),
            ),
          )
              .animate(onPlay: (c) => c.forward())
              .scale(
                  begin: const Offset(0.6, 0.6),
                  end: const Offset(1, 1),
                  duration: 900.ms,
                  curve: Curves.easeOutBack,)
              .then()
              .shimmer(duration: 1200.ms, color: MilesColors.starlight)
              .then()
              .scale(
                  begin: const Offset(1, 1),
                  end: const Offset(1.12, 1.12),
                  duration: 500.ms,),
          const SizedBox(height: 36),
          Text('Opening…', style: Theme.of(context).textTheme.displaySmall)
              .animate(onPlay: (c) => c.repeat())
              .fadeIn(duration: 800.ms)
              .then()
              .fadeOut(duration: 800.ms),
          const SizedBox(height: 8),
          const Text('Everything you saved, all at once.',
                  style: TextStyle(color: MilesColors.taupe),)
              .animate()
              .fadeIn(delay: 600.ms, duration: 900.ms),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// REVEALED
// ─────────────────────────────────────────────────────────────────────────────
class _RevealedView extends StatelessWidget {
  const _RevealedView({
    required this.items,
    required this.loadError,
    required this.onRetry,
    required this.onPlayVoice,
  });
  final List<CapsuleItem> items;
  final String? loadError;
  final VoidCallback onRetry;
  final Future<void> Function(String path) onPlayVoice;

  @override
  Widget build(BuildContext context) {
    if (loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("It's open — but we couldn't read what's inside.\n$loadError",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: MilesColors.taupe, height: 1.5,),),
              const SizedBox(height: 14),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('This capsule was empty. Next time, fill it up 💫',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.taupe),),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: items.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Opened together 💖',
                    style: Theme.of(context).textTheme.displaySmall,)
                .animate()
                .fadeIn(duration: 600.ms),
          );
        }
        final item = items[i - 1];
        return _RevealedItem(item: item, onPlayVoice: onPlayVoice)
            .animate()
            .fadeIn(delay: (180 * i).ms, duration: 600.ms)
            .slideY(begin: 0.12, end: 0, curve: Curves.easeOutCubic);
      },
    );
  }
}

class _RevealedItem extends StatefulWidget {
  const _RevealedItem({required this.item, required this.onPlayVoice});
  final CapsuleItem item;
  final Future<void> Function(String path) onPlayVoice;

  @override
  State<_RevealedItem> createState() => _RevealedItemState();
}

class _RevealedItemState extends State<_RevealedItem> {
  /// Signed once per item, not once per rebuild: a FutureBuilder handed a
  /// fresh future in build() re-signed the photo on every rebuild of the
  /// list — a storage round trip each, for a URL that is good for an hour.
  late Future<String> _url = _sign();

  Future<String> _sign() {
    final path = widget.item.mediaUrl;
    return path == null ? Future.value('') : CapsuleRepository.signedUrl(path);
  }

  @override
  void didUpdateWidget(_RevealedItem old) {
    super.didUpdateWidget(old);
    if (old.item.mediaUrl != widget.item.mediaUrl) _url = _sign();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    Container card(Widget child) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: MilesColors.surface1,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.14)),
          ),
          child: child,
        );

    switch (item.type) {
      case CapsuleItemType.note:
        return card(Text(item.contentText ?? '',
            style: const TextStyle(
                color: MilesColors.cream50, fontSize: 16, height: 1.45,),),);
      case CapsuleItemType.photo:
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: FutureBuilder<String>(
            future: _url,
            builder: (context, snap) {
              if (!snap.hasData || snap.data!.isEmpty) {
                return Container(
                    height: 200,
                    color: MilesColors.surface2,
                    child: const Center(child: CircularProgressIndicator()),);
              }
              // cacheWidth bounds the DECODE, not the file — the same reason
              // gallery_viewer.dart:257-260 gives for its decodeWidth. A
              // capsule photo is the untouched original (capsule_fill_screen
              // uploads the whole file and the repository writes no thumbnail),
              // so a 12-megapixel reveal decoded at source resolution is ~48 MB
              // of raster per card. A handful of them blew past the image cache
              // and OOM-killed the app at the one moment the product exists for.
              return Image.network(
                snap.data!,
                fit: BoxFit.cover,
                width: double.infinity,
                cacheWidth:
                    (MediaQuery.sizeOf(context).width *
                            MediaQuery.devicePixelRatioOf(context))
                        .round(),
              );
            },
          ),
        );
      case CapsuleItemType.voice:
        return card(Row(
          children: [
            GestureDetector(
              onTap: item.mediaUrl == null
                  ? null
                  : () => widget.onPlayVoice(item.mediaUrl!),
              child: Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: MilesColors.ember,),
                child: const Icon(Icons.play_arrow,
                    color: MilesColors.cream50,),
              ),
            ),
            const SizedBox(width: 14),
            const Text('A voice memo for you 🎙️',
                style: TextStyle(color: MilesColors.cream50),),
          ],
        ),);
    }
  }
}
