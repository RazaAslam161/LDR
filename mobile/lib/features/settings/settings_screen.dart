import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/config.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/love_text_field.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController();
  final _status = TextEditingController();
  bool _busy = false;
  bool _savingProfile = false;
  String? _error;
  bool _seeded = false;
  String _locationMode = 'off';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLocationMode());
  }

  Future<void> _loadLocationMode() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final mine = await PresenceService.fetchMine(couple.id);
    if (mounted) {
      setState(() => _locationMode = mine?.locationSharingMode ?? 'off');
    }
  }

  Future<void> _changeLocationSharing() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final opt in const [
              ['off', 'Off'],
              ['city', 'City only'],
              ['precise', 'Precise location'],
            ])
              ListTile(
                title: Text(opt[1],
                    style: const TextStyle(color: MilesColors.cream50)),
                trailing: _locationMode == opt[0]
                    ? const Icon(Icons.check, color: MilesColors.blush)
                    : null,
                onTap: () => Navigator.pop(ctx, opt[0]),
              ),
          ],
        ),
      ),
    );
    if (mode == null) return;
    if (mode == 'off') {
      await PresenceService.setSharingMode(couple.id, 'off');
    } else {
      await LocationService.shareOnce(couple.id, mode);
    }
    if (mounted) {
      setState(() => _locationMode = mode);
      _toast('Location sharing updated');
    }
  }

  String get _locationLabel => _locationMode == 'off'
      ? 'Off'
      : _locationMode == 'city'
          ? 'City only'
          : 'Precise location';

  @override
  void dispose() {
    _name.dispose();
    _status.dispose();
    super.dispose();
  }

  void _seed(Profile? profile) {
    if (_seeded || profile == null) return;
    _seeded = true;
    _name.text = profile.displayName;
    _status.text = profile.statusMessage ?? '';
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _saveProfile() async {
    if (_name.text.trim().isEmpty) {
      _toast('Your name can\'t be empty.');
      return;
    }
    setState(() => _savingProfile = true);
    try {
      await SupabaseRepository.updateMyProfile(
        displayName: _name.text.trim(),
        statusMessage: _status.text.trim(),
      );
      await ref.read(sessionProvider.notifier).loadProfile();
      _toast('Profile updated 💕');
    } catch (e) {
      _toast('Could not save profile.');
    }
    if (mounted) setState(() => _savingProfile = false);
  }

  Future<void> _changeTimezone() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      builder: (_) => const _TimezonePicker(),
    );
    if (picked == null) return;
    try {
      await SupabaseRepository.updateMyProfile(timezone: picked);
      await ref.read(sessionProvider.notifier).loadProfile();
      _toast('Timezone updated');
    } catch (_) {
      _toast('Could not update timezone.');
    }
  }

  Future<void> _removePartner(String partnerName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: Text('Disconnect from $partnerName?'),
        content: const Text(
          'This will unlink your accounts. Your private data and time capsules '
          'are preserved, but you\'ll both need to re-pair to reconnect. '
          'This cannot be undone.',
          style: TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB83A57)), // passionCrimson
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await SupabaseRepository.leaveCouple();
      await ref.read(sessionProvider.notifier).loadProfile();
      if (mounted) context.go('/couple');
    } catch (_) {
      _toast('Could not disconnect. Try again.');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleModestMode(bool newValue) async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    if (newValue == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: MilesColors.surface1,
          title: const Text('Enable Closer?'),
          content: const Text(
            'This reveals the intimacy module for both of you. Everything in '
            'Closer is end-to-end encrypted. You can re-enable Modest Mode any '
            'time.',
            style: TextStyle(color: MilesColors.taupe, height: 1.5),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Enable')),
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
          coupleId: couple.id, enabled: !newValue);
      if (newValue == true) {
        try {
          await SupabaseRepository.publishMyPublicKey();
        } catch (_) {}
      }
      await ref.read(sessionProvider.notifier).loadProfile();
    } catch (e) {
      setState(() => _error = 'Could not update.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    // Drop this device's push token while still authenticated.
    await FcmService.clearToken();
    await ref.read(sessionProvider.notifier).signOut();
    if (mounted) context.go('/signin');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final profile = session.profile;
    final partner = session.partner;
    final isModest = couple?.modestMode ?? true;
    _seed(profile);

    return Scaffold(
      backgroundColor: Colors.transparent,
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
            // ── Profile ──────────────────────────────────────────
            const _SectionHeader(label: 'Profile'),
            LoveTextField(
              label: 'Display name',
              controller: _name,
              hint: 'What should we call you?',
              maxLength: 30,
            ),
            const SizedBox(height: 16),
            LoveTextField(
              label: 'Status',
              controller: _status,
              hint: 'A little note your partner sees',
              maxLength: 60,
            ),
            const SizedBox(height: 16),
            GlowButton(
              label: 'Save profile',
              color: MilesColors.blush,
              loading: _savingProfile,
              onPressed: _savingProfile ? null : _saveProfile,
            ),

            const SizedBox(height: 28),

            // ── Timezone ─────────────────────────────────────────
            const _SectionHeader(label: 'Timezone'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                profile?.timezone.replaceAll('_', ' ') ?? '—',
                style: const TextStyle(color: MilesColors.cream50),
              ),
              subtitle: const Text('Used for the countdown & sky',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, color: MilesColors.gilt),
              onTap: _changeTimezone,
            ),

            const SizedBox(height: 28),

            // ── Location ─────────────────────────────────────────
            const _SectionHeader(label: 'Location sharing'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_locationLabel,
                  style: const TextStyle(color: MilesColors.cream50)),
              subtitle: const Text('Only your partner can ever see this',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, color: MilesColors.gilt),
              onTap: _changeLocationSharing,
            ),

            const SizedBox(height: 28),

            // ── Reach alerts ─────────────────────────────────────
            const _SectionHeader(label: 'Reach alerts'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Full-screen alerts',
                  style: TextStyle(color: MilesColors.cream50)),
              subtitle: const Text(
                  'Let your partner wake your screen when they reach for you',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, color: MilesColors.gilt),
              onTap: FsiPermission.openSettings,
            ),

            const SizedBox(height: 28),

            // ── Privacy ──────────────────────────────────────────
            const _SectionHeader(label: 'Privacy'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: !isModest,
              onChanged: _busy ? null : _toggleModestMode,
              activeThumbColor: MilesColors.ember,
              title: const Text('Closer (intimacy module)',
                  style: TextStyle(color: MilesColors.cream50)),
              subtitle: Text(
                isModest
                    ? 'Hidden. Reveal for both partners.'
                    : 'Visible. End-to-end encrypted.',
                style: const TextStyle(fontSize: 12, color: MilesColors.taupe),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child:
                    Text(_error!, style: const TextStyle(color: MilesColors.blush)),
              ),

            const SizedBox(height: 28),

            // ── Partner ──────────────────────────────────────────
            const _SectionHeader(label: 'Partner'),
            if (partner != null) ...[
              GlassPanel(
                child: Row(
                  children: [
                    const Text('💞', style: TextStyle(fontSize: 24)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(partner.displayName,
                              style: const TextStyle(
                                  color: MilesColors.cream50,
                                  fontWeight: FontWeight.w600)),
                          Text(partner.timezone.replaceAll('_', ' '),
                              style: const TextStyle(
                                  color: MilesColors.taupe, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB83A57),
                  side: const BorderSide(color: Color(0x55B83A57)),
                ),
                onPressed:
                    _busy ? null : () => _removePartner(partner.displayName),
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Remove partner'),
              ),
            ] else
              const Text('Not linked yet.',
                  style: TextStyle(color: MilesColors.taupe)),

            const SizedBox(height: 28),

            // ── Account ──────────────────────────────────────────
            const _SectionHeader(label: 'Account'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout, color: MilesColors.ember),
              title: const Text('Sign out',
                  style: TextStyle(color: MilesColors.ember)),
              onTap: _signOut,
            ),

            const SizedBox(height: 40),
            const Center(
              child: Text('Tethered · v0.1.0',
                  style: TextStyle(fontSize: 11, color: MilesColors.faint)),
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 2,
          fontWeight: FontWeight.w600,
          color: MilesColors.gilt,
        ),
      ),
    );
  }
}

/// Searchable timezone picker over the curated city list.
class _TimezonePicker extends StatefulWidget {
  const _TimezonePicker();

  @override
  State<_TimezonePicker> createState() => _TimezonePickerState();
}

class _TimezonePickerState extends State<_TimezonePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = commonTimezones
        .where((tz) =>
            tz.toLowerCase().contains(_query.toLowerCase().replaceAll(' ', '_')))
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Choose your timezone',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            style: const TextStyle(color: MilesColors.cream50),
            decoration: const InputDecoration(
                hintText: 'Search a city…', prefixIcon: Icon(Icons.search)),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: filtered.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(filtered[i].replaceAll('_', ' '),
                    style: const TextStyle(color: MilesColors.cream50)),
                onTap: () => Navigator.pop(context, filtered[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
