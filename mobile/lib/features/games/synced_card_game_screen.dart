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
import 'package:miles/features/games/no_repeat_bag.dart';

/// A synced "same card on both phones" game (Would You Rather, Never Have I
/// Ever). Either partner can draw the next card and both jump to it; a live
/// answer strip lets them respond in real time.
class SyncedCardGameScreen extends ConsumerStatefulWidget {
  const SyncedCardGameScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.emoji,
    required this.cards,
    required this.gameKey,
    this.accent = MilesColors.blush,
  });

  final String title;
  final String subtitle;
  final String emoji;
  final List<String> cards;
  final String gameKey;
  final Color accent;

  @override
  ConsumerState<SyncedCardGameScreen> createState() =>
      _SyncedCardGameScreenState();
}

class _SyncedCardGameScreenState extends ConsumerState<SyncedCardGameScreen> {
  ManagedSubscription? _sub;
  Timer? _syncTimer;
  String? _coupleId;
  String? _myUid;
  bool _started = false;
  String? _card;

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    _coupleId = s.couple?.id;
    _myUid = s.profile?.id;
    reportScreen(ref, widget.gameKey);
    final cid = _coupleId;
    if (cid != null) {
      _sub = ManagedSubscription.start(() => SupabaseService.client
          .channel('gcard:${widget.gameKey}:$cid')
          .onBroadcast(event: 'card', callback: _onCard)
          .onBroadcast(event: 'sync', callback: _onSync)
          .subscribe());
      _syncTimer = Timer(const Duration(milliseconds: 900), () {
        _sub?.channel
            ?.sendBroadcastMessage(event: 'sync', payload: {'from': _myUid});
      });
    }
  }

  @override
  void dispose() {
    reportActiveTab(ref);
    _syncTimer?.cancel();
    _sub?.dispose();
    super.dispose();
  }

  void _onSync(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid) return;
    if (_started) _broadcast();
  }

  void _onCard(Map<String, dynamic> payload) {
    if (payload['from'] == _myUid || !mounted) return;
    final text = payload['text']?.toString();
    if (text != null) NoRepeatBag.markSeen('card_${widget.gameKey}', text);
    setState(() {
      _started = true;
      _card = text;
    });
  }

  void _broadcast() {
    _sub?.channel?.sendBroadcastMessage(
        event: 'card', payload: {'from': _myUid, 'text': _card});
  }

  Future<void> _next() async {
    if (widget.cards.isEmpty) return;
    final card = await NoRepeatBag.draw('card_${widget.gameKey}', widget.cards);
    if (!mounted) return;
    setState(() {
      _started = true;
      _card = card;
    });
    _broadcast();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.title),
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
                Text(widget.subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 13)),
                const SizedBox(height: 16),
                Expanded(child: _cardArea()),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: widget.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _next,
                    icon: const Icon(Icons.casino_outlined),
                    label: Text(
                        _started ? 'Agla card (dono ke liye)' : 'Shuru karein'),
                  ),
                ),
                if (_coupleId != null) ...[
                  const SizedBox(height: 12),
                  GameChatPanel(
                      coupleId: _coupleId!, gameKey: 'card_${widget.gameKey}'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardArea() {
    if (!_started || _card == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.emoji, style: const TextStyle(fontSize: 52)),
            const SizedBox(height: 16),
            const Text('Shuru karne ke liye neeche tap karo',
                style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
          ],
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: Container(
        key: ValueKey(_card),
        width: double.infinity,
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              widget.accent.withValues(alpha: 0.28),
              MilesColors.ember.withValues(alpha: 0.16),
            ],
          ),
          border: Border.all(color: widget.accent.withValues(alpha: 0.35)),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.emoji, style: const TextStyle(fontSize: 40)),
              const SizedBox(height: 20),
              Text(_card!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 20,
                      height: 1.45,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
