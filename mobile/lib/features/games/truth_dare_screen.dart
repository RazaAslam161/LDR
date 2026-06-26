import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/games/game_chat_panel.dart';
import 'package:miles/features/games/game_content.dart';
import 'package:miles/features/games/truth_dare_deck.dart';

/// Synced Truth or Dare. Both partners see the same card and take turns: on your
/// turn you pick Truth or Dare, the deck draws a card (at the chosen heat
/// level), you do it, then it's their turn. State is shared over a realtime
/// broadcast channel so the two phones stay in lockstep.
class TruthDareScreen extends ConsumerStatefulWidget {
  const TruthDareScreen({super.key});

  @override
  ConsumerState<TruthDareScreen> createState() => _TruthDareScreenState();
}

class _TruthDareScreenState extends ConsumerState<TruthDareScreen> {
  ManagedSubscription? _channel;
  Timer? _syncTimer;
  String? _coupleId;
  String? _myUid;
  String? _partnerUid;

  bool _started = false;
  String? _turn; // whose turn it is to pick
  int _round = 1;
  TDTier _tier = TDTier.flirty;
  TDCard? _card; // null = the turn-holder is still choosing

  bool get _myTurn => _turn != null && _turn == _myUid;

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    _coupleId = s.couple?.id;
    _myUid = s.profile?.id;
    _partnerUid = s.partner?.id;
    reportScreen(ref, 'TruthOrDare');

    _subscribe();
  }

  void _subscribe() {
    final cid = _coupleId;
    if (cid == null) return;
    _channel = ManagedSubscription.start(() => SupabaseService.client
        .channel('game_td:$cid')
        .onBroadcast(event: 'state', callback: _onState)
        .onBroadcast(event: 'sync', callback: _onSync)
        .subscribe());
    // On (re)connect, ask the partner to re-share the current game state.
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 900), () {
      _channel?.channel
          ?.sendBroadcastMessage(event: 'sync', payload: {'from': _myUid});
    });
  }

  @override
  void dispose() {
    reportActiveTab(ref);
    _syncTimer?.cancel();
    _channel?.dispose();
    super.dispose();
  }

  void _onSync(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid) return;
    if (_started) _broadcast(); // someone joined → share current state
  }

  void _onState(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid || !mounted) return;
    final cardJson = payload['card'];
    final card = cardJson is Map
        ? TDCard.fromJson(cardJson.cast<String, dynamic>())
        : null;
    if (card != null) {
      markTDSeen(card); // keep the no-repeat shared across phones
    }
    setState(() {
      _started = true;
      _turn = payload['turn'] as String?;
      _round = (payload['round'] as int?) ?? _round;
      _tier = TDTier.values
          .firstWhere((t) => t.name == payload['tier'], orElse: () => _tier);
      _card = card;
    });
  }

  void _broadcast() {
    _channel?.channel?.sendBroadcastMessage(event: 'state', payload: {
      'from': _myUid,
      'turn': _turn,
      'tier': _tier.name,
      'round': _round,
      'card': _card?.toJson(),
    });
  }

  void _start() {
    setState(() {
      _started = true;
      _turn = _myUid;
      _round = 1;
      _card = null;
    });
    _broadcast();
  }

  void _setTier(TDTier t) {
    setState(() => _tier = t);
    if (_started) _broadcast();
  }

  Future<void> _pick(TDType type) async {
    if (!_myTurn || _card != null) return;
    final card = await drawTD(type, _tier);
    if (!mounted) return;
    setState(() => _card = card);
    _broadcast();
  }

  Future<void> _redraw() async {
    final c = _card;
    if (!_myTurn || c == null) return;
    final card = await drawTD(c.type, _tier);
    if (!mounted) return;
    setState(() => _card = card);
    _broadcast();
  }

  void _next() {
    if (!_myTurn) return;
    setState(() {
      _turn = _partnerUid;
      _card = null;
      _round += 1;
    });
    _broadcast();
  }

  @override
  Widget build(BuildContext context) {
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'Partner';
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Truth or Dare'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _tierChips(),
                const SizedBox(height: 16),
                Expanded(child: _body(partnerName)),
                if (_started)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Round $_round',
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 12)),
                  ),
                if (_coupleId != null) ...[
                  const SizedBox(height: 10),
                  GameChatPanel(coupleId: _coupleId!, gameKey: 'td'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tierChips() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final t in TDTier.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text('${t.emoji} ${t.label}'),
              selected: _tier == t,
              onSelected: (_) => _setTier(t),
              labelStyle: TextStyle(
                  color: _tier == t ? MilesColors.night : MilesColors.cream50,
                  fontWeight: FontWeight.w600,
                  fontSize: 12),
              selectedColor: MilesColors.gilt,
              backgroundColor: MilesColors.surface2,
              side: BorderSide(color: MilesColors.gilt.withValues(alpha: 0.25)),
            ),
          ),
      ],
    );
  }

  Widget _body(String partnerName) {
    if (!_started) return _startView();
    final card = _card;
    if (card == null) {
      return _myTurn
          ? _pickView()
          : _waitView('$partnerName apni baari soch raha/rahi hai…');
    }
    return _cardView(card, partnerName);
  }

  Widget _startView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🎲', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 20),
          const Text('Truth or Dare',
              style: TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 22,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Baari baari Truth ya Dare chuno — dono ke phone par ek hi card '
              'dikhega. Upar se mood (Cute / Flirty / Spicy) chuno aur shuru karo. '
              'Dare mein photo/voice "jitna comfortable ho" — koi zabardasti nahi. 💛',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: MilesColors.taupe, fontSize: 13.5, height: 1.5),
            ),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: MilesColors.blush,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            onPressed: _start,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Shuru karein'),
          ),
        ],
      ),
    );
  }

  Widget _pickView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Tumhari baari! 💫',
              style: TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Kya chunoge?',
              style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
          const SizedBox(height: 28),
          _bigChoice(
            label: 'Truth',
            sub: 'Sach bolna hai',
            icon: Icons.psychology_alt_outlined,
            color: MilesColors.sage,
            onTap: () => _pick(TDType.truth),
          ),
          const SizedBox(height: 16),
          _bigChoice(
            label: 'Dare',
            sub: 'Himmat dikhao',
            icon: Icons.local_fire_department_outlined,
            color: MilesColors.ember,
            onTap: () => _pick(TDType.dare),
          ),
        ],
      ),
    );
  }

  Widget _bigChoice({
    required String label,
    required String sub,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(colors: [
            color.withValues(alpha: 0.30),
            color.withValues(alpha: 0.14),
          ]),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 34),
            const SizedBox(width: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 20,
                        fontWeight: FontWeight.w700)),
                Text(sub,
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _waitView(String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: MilesColors.blush),
          const SizedBox(height: 20),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MilesColors.cream50, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _cardView(TDCard card, String partnerName) {
    final isTruth = card.type == TDType.truth;
    final accent = isTruth ? MilesColors.sage : MilesColors.ember;
    final typeLabel = isTruth ? 'TRUTH' : 'DARE';
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.28),
                  MilesColors.ember.withValues(alpha: 0.14),
                ],
              ),
              border: Border.all(color: accent.withValues(alpha: 0.4)),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Text('${card.tier.emoji}  $typeLabel',
                        style: TextStyle(
                            color: accent,
                            fontSize: 13,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 24),
                  Text(card.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 21,
                          height: 1.5,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_myTurn) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: MilesColors.blush,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              onPressed: _next,
              icon: const Icon(Icons.check_rounded),
              label: Text('Ho gaya — ab $partnerName ki baari'),
            ),
          ),
          TextButton.icon(
            onPressed: _redraw,
            icon: const Icon(Icons.casino_outlined,
                color: MilesColors.taupe, size: 18),
            label: const Text('Yeh nahi — naya card do',
                style: TextStyle(color: MilesColors.taupe)),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '$partnerName ko yeh $typeLabel mila — unke karne ka intezaar… 👀',
              textAlign: TextAlign.center,
              style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
            ),
          ),
      ],
    );
  }
}
