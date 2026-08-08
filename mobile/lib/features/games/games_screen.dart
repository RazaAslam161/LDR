import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/content_language.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/language_toggle.dart';
import 'package:miles/features/shell/app_drawer.dart';

/// Games hub — a little arcade of couple mini-games. Truth or Dare is synced
/// (both phones share the turn); the rest are quick local card games.
class GamesScreen extends ConsumerStatefulWidget {
  const GamesScreen({super.key});

  @override
  ConsumerState<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends ConsumerState<GamesScreen> {
  @override
  void initState() {
    super.initState();
    reportScreen(ref, 'Games');
  }

  @override
  void dispose() {
    reportActiveTab(ref);
    super.dispose();
  }

  static List<_Game> _gamesIn(ContentLanguage lang) {
    final en = lang == ContentLanguage.english;
    return [
      _Game(
        emoji: '🎲',
        title: 'Truth or Dare',
        subtitle: en
            ? 'Take turns — truth or nerve, from Cute to Spicy'
            : 'Baari baari sach ya himmat — Cute se Spicy tak',
        route: '/app/games/truth-dare',
        accent: MilesColors.ember,
        synced: true,
      ),
      _Game(
        emoji: '🤔',
        title: 'Would You Rather',
        subtitle: en
            ? 'This or that? Make each other choose'
            : 'Yeh ya woh? Ek dusre ko choose karne par majboor karo',
        route: '/app/games/would-you-rather',
        accent: MilesColors.sage,
        synced: false,
      ),
      _Game(
        emoji: '🙊',
        title: 'Never Have I Ever',
        subtitle: en
            ? 'I have never… let the secrets out, laughing'
            : 'Maine kabhi nahi… raaz khulne do, hans-hans ke',
        route: '/app/games/never-have-i-ever',
        accent: MilesColors.blush,
        synced: false,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(contentLanguageProvider);
    final en = lang == ContentLanguage.english;

    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Games'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        actions: const [PartnerHereAction(), LanguageToggle()],
      ),
      body: EmberBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(en ? 'Play together 🎮' : 'Saath khelo 🎮',
                  style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 20,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                  en
                      ? 'Close even from far away — play one today.'
                      : 'Door reh kar bhi paas — ek game khelo aaj.',
                  style: const TextStyle(
                      color: MilesColors.taupe, fontSize: 13)),
              const SizedBox(height: 20),
              for (final g in _gamesIn(lang)) _card(g),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(_Game g) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: () => context.push(g.route),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                g.accent.withValues(alpha: 0.22),
                MilesColors.surface1,
              ],
            ),
            border: Border.all(color: g.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Text(g.emoji, style: const TextStyle(fontSize: 38)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(g.title,
                            style: const TextStyle(
                                color: MilesColors.cream50,
                                fontSize: 17,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        if (g.synced)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: MilesColors.gilt.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('LIVE',
                                style: TextStyle(
                                    color: MilesColors.gilt,
                                    fontSize: 9,
                                    letterSpacing: 1,
                                    fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(g.subtitle,
                        style: const TextStyle(
                            color: MilesColors.taupe,
                            fontSize: 12.5,
                            height: 1.3)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: MilesColors.gilt),
            ],
          ),
        ),
      ),
    );
  }
}

class _Game {
  const _Game({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.route,
    required this.accent,
    required this.synced,
  });
  final String emoji;
  final String title;
  final String subtitle;
  final String route;
  final Color accent;
  final bool synced;
}
