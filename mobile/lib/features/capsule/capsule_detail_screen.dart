import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
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

class _CapsuleDetailScreenState extends ConsumerState<CapsuleDetailScreen> {
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

  final AudioPlayer _player = AudioPlayer();
  ManagedSubscription? _channel;

  @override
  void initState() {
    super.initState();
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
    setState(() => _checking = true);
    _prox = ProximityService();
    await _prox!.start(
      coupleId: _capsule.coupleId,
      onUpdate: (s) {
        if (mounted) setState(() => _proxStatus = s);
      },
    );
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
    required this.onOpen,
  });

  final Capsule capsule;
  final bool checking;
  final ProximityStatus? proxStatus;
  final bool canOpen;
  final VoidCallback onCheckProximity;
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hintCard(
            'Location is off. A "when you\'re together" capsule needs it to '
            "know you've reunited. ${capsule.unlockMode == CapsuleUnlockMode.both ? 'It can still open on its date.' : ''}",
            icon: Icons.location_off,
          ),
          const SizedBox(height: 8),
          const OutlinedButton(
            onPressed: Geolocator.openAppSettings,
            child: Text('Open location settings'),
          ),
        ],
      );
    }
    if (s.withinRange) {
      return _hintCard("You're together 💞  Open it.",
          icon: Icons.favorite, color: MilesColors.sage,);
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
          BreathingGlow(
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

class _RevealedItem extends StatelessWidget {
  const _RevealedItem({required this.item, required this.onPlayVoice});
  final CapsuleItem item;
  final Future<void> Function(String path) onPlayVoice;

  @override
  Widget build(BuildContext context) {
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
            future: item.mediaUrl == null
                ? Future.value('')
                : CapsuleRepository.signedUrl(item.mediaUrl!),
            builder: (context, snap) {
              if (!snap.hasData || snap.data!.isEmpty) {
                return Container(
                    height: 200,
                    color: MilesColors.surface2,
                    child: const Center(child: CircularProgressIndicator()),);
              }
              return Image.network(snap.data!,
                  fit: BoxFit.cover, width: double.infinity,);
            },
          ),
        );
      case CapsuleItemType.voice:
        return card(Row(
          children: [
            GestureDetector(
              onTap: item.mediaUrl == null
                  ? null
                  : () => onPlayVoice(item.mediaUrl!),
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
