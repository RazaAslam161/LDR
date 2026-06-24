import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';

/// Side drawer — partner presence, sign-out, future settings.
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final partner = session.partner;

    return Drawer(
      backgroundColor: const Color(0xFF0B0F16),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF6F58),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Tethered',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 40),
              if (partner != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141B26).withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'YOUR PERSON',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 2,
                          color: Color(0x80F5EFE6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _PresenceDot(status: partner.presenceStatus),
                          const SizedBox(width: 8),
                          Text(
                            partner.displayName,
                            style: const TextStyle(
                              color: Color(0xFFFBF8F4),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        partner.timezone.replaceAll('_', ' '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0x80F5EFE6),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _DrawerTile(
                icon: Icons.lock_clock,
                label: 'Capsule',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/capsule');
                },
              ),
              _DrawerTile(
                icon: Icons.lock_outline,
                label: 'Vault',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/vault');
                },
              ),
              _DrawerTile(
                icon: Icons.touch_app_outlined,
                label: 'Touch',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/touch');
                },
              ),
              _DrawerTile(
                icon: Icons.favorite_border,
                label: 'Together',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/together');
                },
              ),
              _DrawerTile(
                icon: Icons.schedule,
                label: 'Rituals',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/rituals');
                },
              ),
              _DrawerTile(
                icon: Icons.question_answer,
                label: 'Daily Question',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/prompt');
                },
              ),
              _DrawerTile(
                icon: Icons.timeline,
                label: 'Timeline',
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/timeline');
                },
              ),
              const Spacer(),
              ListTile(
                leading:
                    const Icon(Icons.settings, color: Color(0x80F5EFE6)),
                title: const Text(
                  'Settings',
                  style: TextStyle(color: Color(0x80F5EFE6)),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/app/settings');
                },
              ),
              TextButton(
                onPressed: () async {
                  await SupabaseRepository.signOut();
                  await ref.read(sessionProvider.notifier).signOut();
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                child: const Text(
                  'Sign out',
                  style: TextStyle(color: Color(0x80F5EFE6)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresenceDot extends StatelessWidget {
  const _PresenceDot({required this.status});
  final dynamic status;

  @override
  Widget build(BuildContext context) {
    final Color color;
    // Pull the status name from the enum.
    final name = status.toString();
    if (name.contains('asleep')) {
      color = const Color(0x4DF5EFE6);
    } else if (name.contains('busy')) {
      color = const Color(0xFFEF6F58);
    } else {
      color = const Color(0xFF34D399);
    }
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFFFBF8F4)),
      title: Text(
        label,
        style: const TextStyle(color: Color(0xFFFBF8F4)),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onTap: onTap,
    );
  }
}
