import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/closer/pick_for_us/pick_for_us_repository.dart';

/// "Pick for us" dice — consensual spontaneity. Three tiers (warm → bold);
/// both partners must tap "let's go bolder" to unlock the next tier.
class PickForUsScreen extends ConsumerStatefulWidget {
  const PickForUsScreen({super.key});

  @override
  ConsumerState<PickForUsScreen> createState() => _PickForUsScreenState();
}

class _PickForUsScreenState extends ConsumerState<PickForUsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  bool _loading = true;
  String? _error;

  /// { tierId → { userId → granted } }
  Map<String, Map<String, bool>> _consents = {};

  /// My own most recent consent request, so the UI can show a waiting state.
  /// tierId → did *I* tap to unlock?
  Map<String, bool> _myAsk = {};

  List<DiceRoll> _history = const [];
  List<String>? _currentRoll; // null = no roll shown yet

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;
    if (couple == null || me == null || partner == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Link your partner to roll together.';
        });
      }
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        PickForUsRepository.fetchConsents(coupleId: couple.id),
        PickForUsRepository.fetchRecent(coupleId: couple.id),
      ]);
      final consents = results[0] as Map<String, Map<String, bool>>;
      final history = results[1] as List<DiceRoll>;

      if (!mounted) return;
      setState(() {
        _consents = consents;
        _history = history;
        // Track what *I've* asked for to show a pending state until partner
        // matches.
        _myAsk = {
          for (final t in DiceTier.all)
            t.id: (consents[t.id]?[me.id] ?? false),
        };
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(e);
      });
    }
  }

  /// Closer's crypto guards throw `Exception('<sentence the user can act on>')`
  /// (closer_crypto.dart:24,32,46). Anything else landing here is a transport
  /// failure whose toString names the Supabase host.
  String _friendly(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ')
        ? s.substring('Exception: '.length)
        : friendlyAuthError(e);
  }

  bool _tierUnlocked(String tierId, String myId, String partnerId) {
    if (tierId == DiceTier.warm.id) return true; // always enabled
    final map = _consents[tierId] ?? const {};
    return (map[myId] ?? false) && (map[partnerId] ?? false);
  }

  /// Which tiers are currently unlocked, in order. The dice picks one tag
  /// from each.
  List<String> _enabledTierIds(String myId, String partnerId) {
    return DiceTier.all
        .where((t) => _tierUnlocked(t.id, myId, partnerId))
        .map((t) => t.id)
        .toList();
  }

  Future<void> _roll() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;
    if (couple == null || me == null || partner == null) return;

    final enabled = _enabledTierIds(me.id, partner.id);
    if (enabled.isEmpty) return;

    final tags = PickForUsRepository.rollTags(enabled);
    final tier = enabled.last;

    unawaited(_spin.forward(from: 0));
    setState(() {
      _currentRoll = null; // hide while spinning
    });

    // Let the animation play before showing the result.
    await Future<void>.delayed(const Duration(milliseconds: 850));

    try {
      await PickForUsRepository.saveRoll(
        coupleId: couple.id,
        tier: tier,
        tags: tags,
      );
    } catch (_) {
      // Persist failure shouldn't block the in-screen result, but the roll then
      // never appears under "recent" — say so rather than let it just vanish.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("This roll wasn't saved to your history.")),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _currentRoll = tags;
    });
    await _load();
  }

  Future<void> _askHotter(DiceTier tier) async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;
    if (couple == null || me == null || partner == null) return;

    try {
      final updated = await PickForUsRepository.setMyConsent(
        coupleId: couple.id,
        userId: me.id,
        partnerId: partner.id,
        tier: tier.id,
        granted: true,
      );
      if (!mounted) return;
      setState(() {
        _consents[tier.id] = updated;
        _myAsk[tier.id] = true;
      });
      final unlocked = (updated[me.id] ?? false) && (updated[partner.id] ?? false);
      if (unlocked) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tier.emoji} ${tier.label} unlocked'),
            backgroundColor: const Color(0xFF1F2937),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendly(e)),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _askHotter(tier),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final me = session.profile;
    final partner = session.partner;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),)
                  : _error != null
                      ? _CenterMessage(
                          icon: Icons.lock_outline,
                          text: _error!,
                          actionLabel: 'Try again',
                          onAction: _load,
                        )
                      : me == null || partner == null
                          ? const _CenterMessage(
                              icon: Icons.people_outline,
                              text: 'Link your partner to roll together.',
                            )
                          : _buildBody(me.id, partner.id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0x80F5EFE6)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pick for us',
                  style: TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'A roll for spontaneous connection',
                  style: TextStyle(fontSize: 11, color: Color(0x66F5EFE6)),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0x80F5EFE6), size: 20),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(String myId, String partnerId) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        const SizedBox(height: 12),
        _buildDice(myId, partnerId),
        const SizedBox(height: 28),
        _buildTiers(myId, partnerId),
        const SizedBox(height: 24),
        if (_history.isNotEmpty) ...[
          const Text(
            'Recent rolls',
            style: TextStyle(
              color: Color(0xFFFBF8F4),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 12),
          ..._history.map(_buildHistoryItem),
        ],
      ],
    );
  }

  Widget _buildDice(String myId, String partnerId) {
    return Center(
      child: Column(
        children: [
          // The spinning die
          AnimatedBuilder(
            animation: _spin,
            builder: (context, child) {
              final t = _spin.value;
              final angle = t * pi * 4; // 2 full rotations
              final scale = 1.0 - 0.08 * sin(t * pi);
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..rotateZ(angle)
                  ..scale(scale),
                child: child,
              );
            },
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: const Color(0xFFEF6F58),
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFEF6F58).withValues(alpha: 0.3),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Center(
                child: Text('🎲', style: TextStyle(fontSize: 44)),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Result card
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _currentRoll == null
                ? Container(
                    key: const ValueKey('empty'),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16,),
                    decoration: BoxDecoration(
                      color: MilesColors.surface1,
                      borderRadius: BorderRadius.circular(20),
                      border:
                          Border.all(color: const Color(0x1aF5EFE6)),
                    ),
                    child: const Text(
                      'Tap roll and let the dice decide.',
                      style: TextStyle(color: Color(0x99F5EFE6)),
                    ),
                  )
                : Container(
                    key: const ValueKey('result'),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFEF6F58), Color(0xFFE0553D)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Your combo',
                          style: TextStyle(
                            color: Color(0xFF0B0F16),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: _currentRoll!
                              .map(
                                (t) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6,),
                                  decoration: BoxDecoration(
                                    // A scrim over the card's own ember
                                    // gradient, for the same reason.
                                    color: const Color(0xFF0B0F16)
                                        .withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(40),
                                  ),
                                  child: Text(
                                    diceTagLabel(t),
                                    style: const TextStyle(
                                      color: Color(0xFF0B0F16),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                  ),
          ),

          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _spin.isAnimating ? null : _roll,
            icon: const Icon(Icons.casino, size: 18),
            label: const Text('Roll'),
          ),
        ],
      ),
    );
  }

  Widget _buildTiers(String myId, String partnerId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Tiers',
          style: TextStyle(
            color: Color(0xFFFBF8F4),
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 12),
        ...DiceTier.all.map((t) => _buildTierRow(t, myId, partnerId)),
      ],
    );
  }

  Widget _buildTierRow(DiceTier tier, String myId, String partnerId) {
    final unlocked = _tierUnlocked(tier.id, myId, partnerId);
    final isWarm = tier.id == DiceTier.warm.id;
    final tierMap = _consents[tier.id] ?? const {};
    final mine = tierMap[myId] ?? false;
    final theirs = tierMap[partnerId] ?? false;
    final iAsked = _myAsk[tier.id] ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: unlocked
              ? const Color(0xFFEF6F58).withValues(alpha: 0.4)
              : const Color(0x1aF5EFE6),
        ),
      ),
      child: Row(
        children: [
          Text(tier.emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tier.label,
                  style: const TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tier.tags.map(diceTagLabel).join(' · '),
                  style: const TextStyle(
                      color: Color(0x80F5EFE6), fontSize: 11,),
                ),
              ],
            ),
          ),
          if (isWarm)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: MilesColors.tint(const Color(0xFFEF6F58), 0.15),
                borderRadius: BorderRadius.circular(40),
              ),
              child: const Text(
                'Always on',
                style: TextStyle(
                  color: Color(0xFFEF6F58),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else if (unlocked)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: MilesColors.tint(const Color(0xFFEF6F58), 0.15),
                borderRadius: BorderRadius.circular(40),
              ),
              child: const Text(
                'Unlocked',
                style: TextStyle(
                  color: Color(0xFFEF6F58),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else if (iAsked && !theirs)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: MilesColors.tint(const Color(0xFFEDE4D3), 0.08),
                borderRadius: BorderRadius.circular(40),
              ),
              child: const Text(
                'Waiting on them',
                style: TextStyle(
                  color: Color(0xFFEDE4D3),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else if (theirs && !mine)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF6F58),
                foregroundColor: const Color(0xFF0B0F16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              onPressed: () => _askHotter(tier),
              child: const Text("Let's go bolder"),
            )
          else
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFEF6F58),
                side: const BorderSide(color: Color(0xFFEF6F58)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              onPressed: () => _askHotter(tier),
              child: const Text("Let's go bolder"),
            ),
        ],
      ),
    );
  }

  Widget _buildHistoryItem(DiceRoll roll) {
    final tier = DiceTier.byId(roll.tier);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        // History sat a step back from the cards above it, at 0.4 where they
        // were 0.6. Resolved, that lands on the scaffold colour rather than
        // the card one — flattening both to surface1 would have made a
        // finished roll and a remembered one look the same.
        color: MilesColors.night,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(tier.emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: roll.tags
                  .map((t) => Text(
                        diceTagLabel(t),
                        style: const TextStyle(
                          color: Color(0xFFF5EFE6),
                          fontSize: 12,
                        ),
                      ),)
                  .toList(),
            ),
          ),
          Text(
            _formatShort(roll.rolledAt),
            style: const TextStyle(color: Color(0x66F5EFE6), fontSize: 10),
          ),
        ],
      ),
    );
  }

  String _formatShort(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${dt.month}/${dt.day}';
  }
}

class _CenterMessage extends StatelessWidget {
  const _CenterMessage({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: const Color(0x80F5EFE6)),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x99F5EFE6), height: 1.5),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
