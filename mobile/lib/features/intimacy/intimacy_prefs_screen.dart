import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/features/intimacy/intimacy_controller.dart';

/// Comfort & consent — every control is one tap, nothing guilt-trips, and the
/// whole layer can be muted instantly.
class IntimacyPrefsScreen extends ConsumerWidget {
  const IntimacyPrefsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(intimacyControllerProvider);
    final ctrl = ref.read(intimacyControllerProvider.notifier);
    final prefs = s.prefs;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Comfort & consent'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'This space only works when it feels right for both of you. '
              'Change anything, anytime — your partner is never told.',
              style: TextStyle(color: MilesColors.taupe, height: 1.6),
            ),
            const SizedBox(height: 24),
            GlassPanel(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                children: [
                  SwitchListTile(
                    value: prefs.receivingEnabled,
                    onChanged: (v) => ctrl.setPrefs(
                        receiving: v, signaling: prefs.signalingEnabled),
                    activeThumbColor: MilesColors.blush,
                    title: const Text('Receive their signals',
                        style: TextStyle(color: MilesColors.cream50)),
                    subtitle: const Text(
                        'See it when you\'re both feeling close.',
                        style:
                            TextStyle(color: MilesColors.taupe, fontSize: 12.5)),
                  ),
                  const Divider(height: 1, color: Color(0x18D9A86C)),
                  SwitchListTile(
                    value: prefs.signalingEnabled,
                    onChanged: (v) => ctrl.setPrefs(
                        receiving: prefs.receivingEnabled, signaling: v),
                    activeThumbColor: MilesColors.blush,
                    title: const Text('Send my own signals',
                        style: TextStyle(color: MilesColors.cream50)),
                    subtitle: const Text(
                        'Let you reach out first when you\'re in the mood.',
                        style:
                            TextStyle(color: MilesColors.taupe, fontSize: 12.5)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () async {
                await ctrl.muteAll();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Intimacy layer muted. Turn it back on '
                            'whenever you like.')),
                  );
                }
              },
              icon: const Icon(Icons.notifications_off_outlined),
              label: const Text('Mute the whole intimacy layer'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Muting turns off both sending and receiving, and quietly clears '
              'any signal you\'ve left. No notice is sent to your partner.',
              style: TextStyle(color: MilesColors.faint, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
