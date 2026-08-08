import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/content_language.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/language_toggle.dart';
import 'package:miles/features/games/game_chat_panel.dart';
import 'package:miles/features/games/game_content.dart';
import 'package:miles/features/games/no_repeat_bag.dart';

/// The two decks this screen can deal.
///
/// Everything that differs between them lives here rather than in the router,
/// because the card text is now language-dependent and a route builder has no
/// `ref` to ask which language the reader wants.
enum CardDeck {
  wouldYouRather('wyr', 'Would You Rather', '🤔', MilesColors.sage),
  neverHaveIEver('nhie', 'Never Have I Ever', '🙊', MilesColors.blush);

  const CardDeck(this.key, this.title, this.emoji, this.accent);

  final String key;
  final String title;
  final String emoji;
  final Color accent;

  List<String> cards(ContentLanguage lang) =>
      this == wouldYouRather ? wyrPool(lang) : nhiePool(lang);

  String subtitle(ContentLanguage lang) => switch ((this, lang)) {
        (wouldYouRather, ContentLanguage.english) =>
          'This or that? One question on both phones — answer below.',
        (wouldYouRather, ContentLanguage.romanUrdu) =>
          'Yeh ya woh? Dono ke phone par ek hi sawaal — jawab neeche do.',
        (neverHaveIEver, ContentLanguage.english) =>
          'I have never… be honest, and answer below.',
        (neverHaveIEver, ContentLanguage.romanUrdu) =>
          'Maine kabhi nahi… sach bolo, jawab neeche likho.',
      };
}

/// A synced "same card on both phones" game (Would You Rather, Never Have I
/// Ever). Either partner can draw the next card and both jump to it; a live
/// answer strip lets them respond in real time.
class SyncedCardGameScreen extends ConsumerStatefulWidget {
  const SyncedCardGameScreen({super.key, required this.deck});

  final CardDeck deck;

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

  /// Position of [_card] in the deck. Sent to the partner instead of the words,
  /// so their phone can show the same card in whichever language they read.
  int _cardIndex = -1;

  @override
  void initState() {
    super.initState();
    final s = ref.read(sessionProvider);
    _coupleId = s.couple?.id;
    _myUid = s.profile?.id;
    reportScreen(ref, widget.deck.key);
    final cid = _coupleId;
    if (cid != null) {
      _sub = ManagedSubscription.start(() => SupabaseService.client
          .channel('gcard:${widget.deck.key}:$cid')
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
    final index = payload['index'];
    final lang = ref.read(contentLanguageProvider);
    // Their index, our words. Older builds send no index — then their text is
    // all we have, and showing it beats showing nothing.
    final resolved = _cardAt(lang, index is int ? index : -1) ??
        payload['text']?.toString();
    if (resolved != null) NoRepeatBag.markSeen(_bagKey(lang), resolved);
    setState(() {
      _started = true;
      _card = resolved;
      _cardIndex = index is int ? index : -1;
    });
  }

  void _broadcast() {
    _sub?.channel?.sendBroadcastMessage(event: 'card', payload: {
      'from': _myUid,
      'text': _card,
      'index': _cardIndex,
    });
  }

  String? _cardAt(ContentLanguage lang, int index) {
    final cards = widget.deck.cards(lang);
    return index < 0 || index >= cards.length ? null : cards[index];
  }

  /// The no-repeat bag is per language: the two decks hold different strings,
  /// and burning a card in one would retire a question nobody has read.
  String _bagKey(ContentLanguage lang) => 'card_${widget.deck.key}_${lang.name}';

  Future<void> _next() async {
    final lang = ref.read(contentLanguageProvider);
    final cards = widget.deck.cards(lang);
    if (cards.isEmpty) return;
    final card = await NoRepeatBag.draw(_bagKey(lang), cards);
    if (!mounted) return;
    setState(() {
      _started = true;
      _card = card;
      _cardIndex = cards.indexOf(card);
    });
    _broadcast();
  }

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(contentLanguageProvider);
    final english = lang == ContentLanguage.english;

    // Switching language re-renders the card that is up rather than dealing a
    // new one — the same question, in the other tongue.
    ref.listen<ContentLanguage>(contentLanguageProvider, (_, next) {
      final same = _cardAt(next, _cardIndex);
      if (same != null) setState(() => _card = same);
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.deck.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: const [LanguageToggle()],
      ),
      body: EmberBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(widget.deck.subtitle(lang),
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
                      backgroundColor: widget.deck.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _next,
                    icon: const Icon(Icons.casino_outlined),
                    label: Text(
                      _started
                          ? (english ? 'Next card (for both)' : 'Agla card (dono ke liye)')
                          : (english ? 'Start' : 'Shuru karein'),
                    ),
                  ),
                ),
                if (_coupleId != null) ...[
                  const SizedBox(height: 12),
                  GameChatPanel(
                      coupleId: _coupleId!, gameKey: 'card_${widget.deck.key}'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardArea() {
    final english =
        ref.watch(contentLanguageProvider) == ContentLanguage.english;
    if (!_started || _card == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.deck.emoji, style: const TextStyle(fontSize: 52)),
            const SizedBox(height: 16),
            Text(
              english
                  ? 'Tap below to start'
                  : 'Shuru karne ke liye neeche tap karo',
              style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
            ),
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
              widget.deck.accent.withValues(alpha: 0.28),
              MilesColors.ember.withValues(alpha: 0.16),
            ],
          ),
          border: Border.all(color: widget.deck.accent.withValues(alpha: 0.35)),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.deck.emoji, style: const TextStyle(fontSize: 40)),
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
