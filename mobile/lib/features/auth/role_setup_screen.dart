import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/surface_panel.dart';

/// One-time screen after pairing: each partner sets their OWN gender. Gates the
/// cycle feature. The router sends paired users here while gender_set == false.
class RoleSetupScreen extends ConsumerStatefulWidget {
  const RoleSetupScreen({super.key});

  @override
  ConsumerState<RoleSetupScreen> createState() => _RoleSetupScreenState();
}

class _RoleSetupScreenState extends ConsumerState<RoleSetupScreen> {
  String? _saving;

  /// A failed save used to be a permanent trap: the router sends every other
  /// route back to /role-setup while gender_set is false, and this screen had
  /// no sign-out. One failure and the account was unusable forever.
  bool _failed = false;

  Future<void> _pick(String gender) async {
    if (_saving != null) return;
    setState(() => _saving = gender);
    try {
      await SupabaseRepository.setGender(gender);
      // Reloading the profile flips gender_set → the router redirect moves the
      // user on to /app automatically.
      await ref.read(sessionProvider.notifier).loadProfile();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = null;
          _failed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save — try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_failed) ...[
                  // The only way out of the redirect loop. Shown only after a
                  // failure so it never distracts from the happy path.
                  Align(
                    alignment: Alignment.topRight,
                    child: TextButton(
                      onPressed: () async {
                        await ref.read(sessionProvider.notifier).signOut();
                        if (context.mounted) context.go('/signin');
                      },
                      child: const Text('Sign out',
                          style: TextStyle(color: MilesColors.taupe),),
                    ),
                  ),
                ],
                const Text('A little about you',
                    style: TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,),),
                const SizedBox(height: 10),
                const Text(
                  'This tailors a few things for the two of you. You set your '
                  'own — your partner sets theirs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: MilesColors.taupe, fontSize: 14, height: 1.4,),
                ),
                const SizedBox(height: 36),
                _RoleCard(
                  icon: Icons.male_rounded,
                  label: "I'm male",
                  color: MilesColors.sage,
                  busy: _saving == 'male',
                  onTap: () => _pick('male'),
                ),
                const SizedBox(height: 16),
                _RoleCard(
                  icon: Icons.female_rounded,
                  label: "I'm female",
                  color: MilesColors.blush,
                  busy: _saving == 'female',
                  onTap: () => _pick('female'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: SurfacePanel(
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.18),
                border: Border.all(color: color.withValues(alpha: 0.5)),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,),),
            ),
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.chevron_right, color: MilesColors.gilt),
          ],
        ),
      ),
    );
  }
}
