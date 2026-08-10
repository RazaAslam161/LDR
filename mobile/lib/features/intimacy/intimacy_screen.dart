import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/breathing_glow.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/intimacy/intimacy_controller.dart';
import 'package:miles/features/intimacy/intimacy_repository.dart';

/// "In the Mood" — a tender, mutual, opt-in way to signal closeness across
/// distance. Nothing is ever explicit; a signal is only revealed when BOTH
/// partners are open to it in the same window, so no one feels exposed.
class IntimacyScreen extends ConsumerWidget {
  const IntimacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(intimacyControllerProvider);
    final ctrl = ref.read(intimacyControllerProvider.notifier);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('In the Mood'),
        actions: [
          const PartnerHereAction(),
          IconButton(
            tooltip: 'Comfort & consent',
            icon: const Icon(Icons.tune, color: MilesColors.gilt),
            onPressed: () => context.push('/app/intimacy/prefs'),
          ),
        ],
      ),
      body: SafeArea(
        child: s.loading
            ? const Center(child: CircularProgressIndicator())
            : !s.prefs.optedIn
                ? _OptIn(onEnable: () => ctrl.setPrefs(receiving: true, signaling: true))
                : s.mutual
                    ? _MutualMoment(mine: s.mine!, partner: s.partner!)
                    : s.waiting
                        ? _Waiting(mine: s.mine!, onNotTonight: ctrl.notTonight)
                        : _Picker(prefs: s.prefs, onPick: ctrl.signal),
      ),
    );
  }
}

class _OptIn extends StatelessWidget {
  const _OptIn({required this.onEnable});
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        const Center(
          child: BreathingGlow(
            child: Text('🕯️', style: TextStyle(fontSize: 56)),
          ),
        ),
        const SizedBox(height: 28),
        SurfacePanel(
          glow: MilesColors.blush,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('A little closer, tonight',
                  style: Theme.of(context).textTheme.displaySmall,),
              const SizedBox(height: 10),
              const Text(
                "A gentle way to let each other know you're feeling close — "
                'a flicker of warmth across the distance.\n\n'
                'It only ever works both ways: your partner sees your signal '
                "only if they're feeling it too, in the same window. If "
                "they're not, nothing shows, and no one feels put on the spot.",
                style: TextStyle(color: MilesColors.taupe, height: 1.6),
              ),
              const SizedBox(height: 8),
              const Text(
                'You can turn it off, or mute it entirely, any time.',
                style: TextStyle(color: MilesColors.faint, fontSize: 12.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        GlowButton(
          label: 'Turn on, for both of us',
          color: MilesColors.blush,
          icon: Icons.favorite_border,
          onPressed: onEnable,
        ),
        const SizedBox(height: 12),
        const Center(
          child: Text('Off by default · always opt-in',
              style: TextStyle(color: MilesColors.faint, fontSize: 12),),
        ),
      ],
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({required this.prefs, required this.onPick});
  final IntimacyPrefs prefs;
  final void Function(String stateKey) onPick;

  @override
  Widget build(BuildContext context) {
    if (!prefs.signalingEnabled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🤍', style: TextStyle(fontSize: 40)),
              const SizedBox(height: 12),
              const Text(
                "You're set to receive only. Turn on sending in "
                "comfort & consent whenever you'd like to reach out first.",
                textAlign: TextAlign.center,
                style: TextStyle(color: MilesColors.taupe, height: 1.5),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => context.push('/app/intimacy/prefs'),
                child: const Text('Open settings'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('How are you feeling tonight?',
            style: Theme.of(context).textTheme.displaySmall,),
        const SizedBox(height: 8),
        const Text(
          "Tap to let them know. They'll only see it if they're feeling "
          'it too — so it always stays mutual.',
          style: TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        const SizedBox(height: 24),
        for (final m in moodStates) ...[
          _MoodTile(mood: m, onTap: () => onPick(m.key)),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        const Center(
          child: Text('No pressure, ever. Not feeling it? Just close this.',
              style: TextStyle(color: MilesColors.faint, fontSize: 12),),
        ),
      ],
    );
  }
}

class _MoodTile extends StatelessWidget {
  const _MoodTile({required this.mood, required this.onTap});
  final MoodState mood;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SurfacePanel(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Text(mood.emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(mood.label,
                  style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,),),
            ),
            const Icon(Icons.send_rounded,
                size: 18, color: MilesColors.blush,),
          ],
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.mine, required this.onNotTonight});
  final IntimacySignal mine;
  final VoidCallback onNotTonight;

  @override
  Widget build(BuildContext context) {
    final m = moodFor(mine.state);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        Center(
          child: BreathingGlow(
            color: MilesColors.emberSoft,
            child: Container(
              width: 140,
              height: 140,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  MilesColors.surface2,
                  MilesColors.nightDeep,
                ],),
              ),
              child: Center(
                  child: Text(m.emoji, style: const TextStyle(fontSize: 48)),),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Center(
          child: Text('You let them know 💫',
              style: Theme.of(context).textTheme.displaySmall,),
        ),
        const SizedBox(height: 10),
        const Center(
          child: Text(
            "If they're feeling it too, you'll both see it — softly, at the "
            'same time. Until then, this stays just yours.',
            textAlign: TextAlign.center,
            style: TextStyle(color: MilesColors.taupe, height: 1.6),
          ),
        ),
        const SizedBox(height: 32),
        OutlinedButton(
          onPressed: onNotTonight,
          child: const Text('Actually, not tonight'),
        ),
      ],
    );
  }
}

class _MutualMoment extends StatelessWidget {
  const _MutualMoment({required this.mine, required this.partner});
  final IntimacySignal mine;
  final IntimacySignal partner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BreathingGlow(
              period: const Duration(milliseconds: 3200),
              child: Container(
                width: 168,
                height: 168,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    MilesColors.emberSoft,
                    MilesColors.blush,
                    MilesColors.nightDeep,
                  ],),
                ),
                child: const Center(
                    child: Text('💞', style: TextStyle(fontSize: 64)),),
              ),
            )
                .animate()
                .scale(
                    begin: const Offset(0.7, 0.7),
                    end: const Offset(1, 1),
                    duration: 700.ms,
                    curve: Curves.easeOutBack,)
                .shimmer(delay: 400.ms, duration: 1400.ms, color: MilesColors.starlight),
            const SizedBox(height: 30),
            Text("You're both feeling it tonight",
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall,)
                .animate()
                .fadeIn(delay: 300.ms, duration: 800.ms),
            const SizedBox(height: 14),
            SurfacePanel(
              glow: MilesColors.blush,
              child: Column(
                children: [
                  _row('You', moodFor(mine.state)),
                  const Divider(height: 22, color: Color(0x22D9A86C)),
                  _row('Them', moodFor(partner.state)),
                ],
              ),
            ).animate().fadeIn(delay: 600.ms, duration: 900.ms),
            const SizedBox(height: 18),
            const Text("Maybe it's a good night for a call 🌙",
                style: TextStyle(color: MilesColors.taupe),),
          ],
        ),
      ),
    );
  }

  Widget _row(String who, MoodState m) {
    return Row(
      children: [
        Text(m.emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 14),
        Text(who,
            style: const TextStyle(color: MilesColors.faint, fontSize: 12),),
        const Spacer(),
        Text(m.label,
            style: const TextStyle(
                color: MilesColors.cream50, fontWeight: FontWeight.w500,),),
      ],
    );
  }
}
