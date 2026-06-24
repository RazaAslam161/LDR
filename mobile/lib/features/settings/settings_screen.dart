import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _toggleModestMode(bool newValue) async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;

    // The switch is "Closer visible": ON (newValue == true) reveals the module,
    // which means modest_mode must become FALSE. Confirm before revealing —
    // it's a significant change that affects both partners.
    if (newValue == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF141B26),
          title: const Text('Enable Closer?'),
          content: const Text(
            'This reveals the intimacy module for both of you. Your partner '
            'will see it the next time they open the app.\n\n'
            'Everything in Closer is end-to-end encrypted and stays on your '
            'phones. You can re-enable Modest Mode any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SupabaseRepository.setModestMode(
        coupleId: couple.id,
        // switch ON (reveal Closer) → modest_mode OFF, and vice-versa.
        enabled: !newValue,
      );
      // When enabling Closer, also publish our E2EE public key so the partner
      // can derive the shared key when they next open any Closer feature.
      // (Idempotent — publishMyPublicKey upserts.)
      if (newValue == true) {
        try {
          await SupabaseRepository.publishMyPublicKey();
        } catch (_) {
          // Non-fatal: ensureSharedKey will retry on first Closer feature open.
        }
      }
      await ref.read(sessionProvider.notifier).loadProfile();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await ref.read(sessionProvider.notifier).signOut();
    if (mounted) context.go('/signin');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final profile = session.profile;
    final isModest = couple?.modestMode ?? true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            // ─── Account ────────────────────────────────────────
            const _SectionHeader(label: 'Account'),
            _ListTile(
              label: 'Name',
              value: profile?.displayName ?? '—',
            ),
            _ListTile(
              label: 'Timezone',
              value: profile?.timezone.replaceAll('_', ' ') ?? '—',
            ),
            _ListTile(
              label: 'Date of birth',
              value: profile?.birthDate ?? '—',
            ),
            _ListTile(
              label: 'Partner',
              value: session.partner?.displayName ?? 'Not linked yet',
            ),

            const SizedBox(height: 32),

            // ─── Privacy ────────────────────────────────────────
            const _SectionHeader(label: 'Privacy'),
            SwitchListTile(
              value: !isModest,
              onChanged: _busy ? null : _toggleModestMode,
              title: const Text(
                'Closer (intimacy module)',
                style: TextStyle(color: Color(0xFFFBF8F4)),
              ),
              subtitle: Text(
                isModest
                    ? 'Hidden. Reveal for both partners.'
                    : 'Visible. Content is end-to-end encrypted.',
                style: const TextStyle(fontSize: 12, color: Color(0x80F5EFE6)),
              ),
              activeThumbColor: const Color(0xFFEF6F58),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFEF6F58)),
                ),
              ),

            const SizedBox(height: 32),

            // ─── Session ────────────────────────────────────────
            const _SectionHeader(label: 'Session'),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFFEF6F58)),
              title: const Text(
                'Sign out',
                style: TextStyle(color: Color(0xFFEF6F58)),
              ),
              onTap: _signOut,
            ),

            const SizedBox(height: 48),
            Center(
              child: Text(
                'Miles · v0.1.0',
                style: TextStyle(
                  fontSize: 11,
                  color: const Color(0xFFF5EFE6).withValues(alpha: 0.3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 2,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF4937E),
        ),
      ),
    );
  }
}

class _ListTile extends StatelessWidget {
  const _ListTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0x99F5EFE6)),
          ),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFFFBF8F4)),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
