import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/app/config.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/widgets/wordmark.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/key_escrow.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/notification_channel_settings.dart';
import 'package:miles/core/services/notification_state.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/services/update_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/app_lock_pin_sheet.dart';
import 'package:miles/core/widgets/escrow_prompt.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/language_toggle.dart';
import 'package:miles/core/widgets/love_text_field.dart';
import 'package:miles/core/widgets/safety_code_prompt.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/core/widgets/update_sheet.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/legal/faq_screen.dart';
import 'package:miles/features/legal/terms_screen.dart';
import 'package:miles/features/legal/terms_text.dart';
import 'package:miles/features/safety/contact_pause.dart';
import 'package:miles/features/safety/report_service.dart';
import 'package:miles/features/safety/safety_sheets.dart';
import 'package:miles/features/safety/severance_sheet.dart';
import 'package:miles/features/settings/security_code_dialog.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Which face of Settings a route is asking for.
///
/// Build 52 carried real routes for these — `/app/settings/profile`,
/// `/notifications`, `/account` — recovered from its binary. They are pages of
/// ONE screen rather than three widgets because every handler
/// (`_changeAvatar`, `_toggleAppLock`, `_deleteAccount`, and fifteen more)
/// lives in this State; moving them out to get three classes would be a large
/// refactor of working code for no user-visible gain.
enum SettingsPage { root, profile, notifications, account }

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.page = SettingsPage.root});

  final SettingsPage page;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  final _name = TextEditingController();
  final _status = TextEditingController();
  bool _busy = false;
  bool _savingProfile = false;
  String? _error;
  bool _seeded = false;
  String _locationMode = 'off';
  LocationBlock _locationBlock = LocationBlock.none;
  bool _appLock = false;
  bool _escrowMissing = false;
  /// Whether this couple has ever compared their security code. Null while
  /// unknown — no partner, no published key, or the fetch did not land — and
  /// the row then says what it has always said, because "never compared" is a
  /// claim about the two of them and being offline is not evidence for it.
  bool? _codeVerified;
  bool _changingAvatar = false;
  String? _localAvatarUrl;

  Future<void> _changeAvatar() async {
    final file = await PhotoPickerService.pickFromSheet(context,
        shape: PhotoShape.square,);
    if (file == null) return;
    final couple = ref.read(sessionProvider).couple;
    setState(() => _changingAvatar = true);
    try {
      final uid = SupabaseService.currentUserId!;
      final cid = couple?.id ?? uid;
      final path =
          '$cid/avatars/${uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await SupabaseService.client.storage
          .from('couple_media')
          .upload(path, file);
      // The PATH, not a URL — couple_media is private; readers sign it.
      await SupabaseRepository.setAvatarUrl(path);
      if (mounted) {
        setState(() => _localAvatarUrl = path);
        _toast('Photo updated');
      }
    } catch (_) {
      if (mounted) _toast('Could not update photo');
    }
    if (mounted) setState(() => _changingAvatar = false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadLocationMode();
      _loadAppLock();
      _loadEscrow();
      _loadCodeVerified();
      _loadNotificationState();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The repair for a missing location permission happens in the system
    // settings app, and openAppSettings() returns the moment the intent is
    // fired — not when the user comes back. Without this the tile still said
    // "blocked" after they had just unblocked it, which is the same lie in the
    // other direction.
    if (state == AppLifecycleState.resumed) {
      _loadLocationMode();
      _loadNotificationState();
    }
  }

  Future<void> _loadAppLock() async {
    final on = await AppLock.isEnabled();
    if (mounted) setState(() => _appLock = on);
  }

  /// Android's own answer about notifications, re-read on resume because the
  /// user repairs it in the system settings app and comes back.
  NotificationState _notif = const NotificationState();

  Future<void> _loadNotificationState() async {
    final n = await NotificationState.read();
    if (mounted) setState(() => _notif = n);
  }

  Future<void> _loadEscrow() async {
    final missing = await KeyEscrow.isMissing();
    if (mounted) setState(() => _escrowMissing = missing);
  }

  /// Reads the PUBLISHED partner key, not the pinned digest — the same fetch
  /// the dialog makes — because the question the row answers is about the code
  /// the two phones would show each other right now.
  Future<void> _loadCodeVerified() async {
    final verified = await SafetyCodePrompt.isVerified(
      ref.read(sessionProvider).partner?.id,
    );
    if (mounted) setState(() => _codeVerified = verified);
  }

  /// The same dialog and re-authentication the launch prompt uses. That prompt
  /// is dismissible and snoozes for a week, so this row is the standing place
  /// to see the state and repair it without waiting to be asked again.
  Future<void> _fixEscrow() async {
    await EscrowPrompt.show(context);
    await _loadEscrow();
  }

  Future<void> _toggleSounds(bool v) async {
    setState(() => MilesSound.enabled = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(MilesSound.prefKey, v);
    } catch (e) {
      // The live toggle already took effect; only persistence failed — say so
      // rather than silently reverting on next launch.
      debugPrint('[settings] sound pref save failed: $e');
    }
  }

  Future<void> _toggleAppLock(bool v) async {
    if (v) {
      // Enabling: a 4-digit PIN is required so there's ALWAYS a way in (even
      // with no biometrics) — set one if there isn't one yet.
      final needPin = !await AppLock.hasPin();
      if (!mounted) return;
      if (needPin) {
        final set = await showAppLockPinSetup(context);
        if (!set) return; // cancelled → leave the lock off
      }
      await AppLock.setEnabled(true);
      final bio = await AppLock.availableBiometrics();
      if (!mounted) return;
      setState(() => _appLock = true);
      _toast(bio.isEmpty
          ? 'App lock on 🔒 — unlock with your PIN'
          : 'App lock on 🔒 — fingerprint/face or PIN',);
    } else {
      // Disabling: confirm with the PIN first.
      final ok = await showAppLockPinVerify(context);
      if (!ok || !mounted) return;
      await AppLock.setEnabled(false);
      setState(() => _appLock = false);
      _toast('App lock off');
    }
  }

  Future<void> _loadLocationMode() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final mine = await PresenceService.fetchMine(couple.id);
    final block = await LocationService.check();
    if (mounted) {
      setState(() {
        _locationMode = mine?.locationSharingMode ?? 'off';
        _locationBlock = block;
      });
    }
  }

  /// Tapping the tile while it is complaining repairs the permission instead of
  /// re-opening the mode picker — the mode is not what is wrong.
  Future<void> _fixLocationSharing() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final block = await LocationService.resolve(context);
    if (mounted) setState(() => _locationBlock = block);
    if (block == LocationBlock.none) {
      await LocationService.shareOnce(couple.id, _locationMode);
    }
  }

  Future<void> _changeLocationSharing() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    final mode = await showModalBottomSheet<String>(
      context: context,
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
                    style: const TextStyle(color: MilesColors.cream50),),
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
      // setSharingMode writes only the mode, so the last precise fix stayed
      // on the server after the user turned sharing off. This nulls the
      // coordinates with it.
      await PresenceService.setLocation(couple.id, mode: 'off');
      if (mounted) setState(() => _locationBlock = LocationBlock.none);
    } else {
      // Written first and unconditionally. The mode used to be a side effect of
      // a successful fix, so choosing "City only" without permission left the
      // server on the old mode while this screen showed the new one.
      await PresenceService.setSharingMode(couple.id, mode);
      if (!mounted) return;
      // Picking a mode IS the request to share, so a handset that is not
      // allowing it has to say so here rather than do nothing.
      final block = await LocationService.resolve(context);
      if (mounted) setState(() => _locationBlock = block);
      // Push one fix now; Home's foreground loop keeps it fresh while open.
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

  /// The gap between what the mode claims and what the handset allows, in the
  /// user's words. Null when there is no gap.
  String? get _locationProblem => _locationMode == 'off'
      ? null
      : switch (_locationBlock) {
          LocationBlock.none => null,
          LocationBlock.serviceDisabled =>
            "Your phone's location is switched off — tap to fix",
          LocationBlock.denied => "You haven't allowed location yet — tap to fix",
          LocationBlock.deniedForever =>
            'Location is blocked for this app — tap to fix',
        };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  /// Local time, because the row is telling the user when their own phone
  /// starts ringing again. Indefinite pauses have no end to name.
  String _pauseSubtitle() {
    final until = ContactPause.expiresAt;
    if (until == null) return 'On until you turn it back on';
    final local = until.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return 'On until $hh:$mm';
  }

  Future<void> _saveProfile() async {
    if (_name.text.trim().isEmpty) {
      _toast("Your name can't be empty.");
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

  Future<void> _changeGender() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final g in const [
              ['male', 'Male'],
              ['female', 'Female'],
            ])
              ListTile(
                title: Text(g[1],
                    style: const TextStyle(color: MilesColors.cream50),),
                onTap: () => Navigator.pop(ctx, g[0]),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    try {
      await SupabaseRepository.setGender(picked);
      await ref.read(sessionProvider.notifier).loadProfile();
      _toast('Updated');
    } catch (_) {
      _toast('Could not update');
    }
  }

  Future<void> _changeTimezone() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
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

  /// The one destructive action in the app that used to ask for nothing.
  ///
  /// It asked less than deleting an account does, and its dialog was wrong
  /// twice over: the private vault is derived from this account's own seed and
  /// was never at risk, and "this cannot be undone" contradicted the app's own
  /// FAQ two taps away. Both the dialog and its copy are gone; the sheet owns
  /// the wording now, and the sheet is in features/safety because it is read
  /// under the same over-the-shoulder rule as the report and pause sheets.
  Future<void> _removePartner() async {
    final outcome = await showSeveranceSheet(
      context,
      onEnd: _endConnection,
      onStartCeremony: _startUnlink,
      confirmIdentity: _confirmEmergencyIdentity,
    );
    if (!mounted) return;
    // Both follow-ups are opened from HERE rather than from inside the sheet:
    // a sheet that pops itself and then pushes from its own context is
    // pushing onto a route that no longer exists.
    switch (outcome) {
      case SeveranceOutcome.paused:
        await showContactPauseSheet(context);
      case SeveranceOutcome.deleteRequested:
        await _deleteAccount();
      case SeveranceOutcome.unlinkStarted:
        await context.push('/unlink');
      case SeveranceOutcome.ended:
      case null:
        break;
    }
  }

  /// Begins the ceremony. Rethrows so the sheet keeps its own error state —
  /// the same contract [_endConnection] has always had with it.
  Future<void> _startUnlink() async {
    await UnlinkRepository.start();
    await UnlinkState.load();
  }

  /// Proof-of-owner for the exit that skips the seven days: the device
  /// credential first (AppLock arms authInProgress itself, so the disguise
  /// cover stays down through the OS prompt), the account password when no
  /// screen lock is enrolled — the gate must exist on every phone, or the
  /// emergency exit exists on none of the phones that need it most.
  Future<bool> _confirmEmergencyIdentity() async {
    if (await AppLock.available()) {
      if (await AppLock.authenticate()) return true;
      return false;
    }
    if (!mounted) return false;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _EmergencyPasswordDialog(),
    );
    if (password == null || password.isEmpty) return false;
    return SupabaseRepository.reauthenticate(password);
  }

  /// Enforcement first, and the local wipe second — never the other way round.
  ///
  /// The couple id is captured BEFORE anything clears it: loadProfile() nulls
  /// it, and endCouple needs it to clear the unread tally, which is keyed by
  /// couple. The wipe runs in a finally for the reason signOut() documents —
  /// a teardown that only happens when nothing threw is a teardown that skips
  /// exactly the cases it exists for.
  Future<void> _endConnection() async {
    final coupleId = ref.read(sessionProvider).couple?.id;
    setState(() => _busy = true);
    try {
      await SupabaseRepository.leaveCouple();
      try {
        await ref.read(sessionProvider.notifier).endCouple(coupleId);
      } finally {
        await ref.read(sessionProvider.notifier).loadProfile();
      }
      if (mounted) context.go('/couple');
    } catch (e) {
      // Rethrown so the sheet can show its own error and stay open. Swallowing
      // it here would leave the sheet reporting success for a couple that is
      // still very much intact.
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
  }

  Future<void> _toggleModestMode(bool newValue) async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    if (newValue == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Enable Closer?'),
          content: const Text(
            'This makes Closer visible for both of you. You can re-enable '
            'Modest Mode any time.',
            style: TextStyle(color: MilesColors.taupe, height: 1.5),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Enable'),),
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
          coupleId: couple.id, enabled: !newValue,);
      if (newValue == true) {
        // Swallowing this left Closer switched on with no public key published,
        // so every Closer screen sat on "waiting for your partner" forever and
        // nothing here ever said why. Let it fail the whole toggle instead.
        await SupabaseRepository.publishMyPublicKey();
      }
      await ref.read(sessionProvider.notifier).loadProfile();
    } catch (e) {
      setState(() => _error = friendlyAuthError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Play requires an in-app path to delete the account, and requires that it
  /// really deletes rather than deactivates. Typing DELETE is deliberate
  /// friction: this is irreversible and takes the partner's shared history
  /// with it once nobody is left in the couple.
  Future<void> _deleteAccount() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This permanently deletes your account, your messages, your '
              'photos and videos, and everything in your vault. If your '
              'partner has already left, their copy goes too. '
              'This cannot be undone.',
              style: TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Type DELETE to confirm',
              ),
              onChanged: (_) => (ctx as Element).markNeedsBuild(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: MilesColors.danger,),
            onPressed: controller.text.trim().toUpperCase() == 'DELETE'
                ? () => Navigator.pop(ctx, true)
                : null,
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await SupabaseRepository.deleteMyAccount();
      await ref.read(sessionProvider.notifier).signOut();
      if (mounted) context.go('/signin');
    } catch (_) {
      // The account still exists, so say so — a silent failure here reads as
      // "deleted" and the user walks away believing their data is gone.
      _toast('Could not delete your account. Please try again.');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await ref.read(sessionProvider.notifier).signOut();
    if (mounted) context.go('/signin');
  }

  /// Both mailboxes have to agree — Supabase mails a confirmation link to the
  /// current address AND the new one, and nothing changes until both links are
  /// opened. The dialog says so up front, because "check your email" reads as
  /// one link, and a change that stalls after the first tap looks broken when
  /// it is actually waiting on the second mailbox.
  Future<void> _changeEmail() async {
    final current = SupabaseService.client.auth.currentUser?.email;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change email?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "We'll send a confirmation link to "
              '${current ?? 'your current address'} and to the new address. '
              'Your email only changes once you open both. '
              'This replaces the old one everywhere you are signed in.',
              style: const TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'New email'),
              onChanged: (_) => (ctx as Element).markNeedsBuild(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: controller.text.trim().contains('@')
                ? () => Navigator.pop(ctx, true)
                : null,
            child: const Text('Send links'),
          ),
        ],
      ),
    );
    final newEmail = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return;
    try {
      await SupabaseRepository.changeEmail(newEmail);
      _toast('Check both inboxes — the change finishes there.');
    } catch (e) {
      _toast(friendlyAuthError(e));
    }
  }

  /// Worded for the ordinary reasons — a phone that was lost, sold or simply
  /// replaced is the scenario, and the dialog names it without drama. The one
  /// promise that matters is stated twice, here and on the row: THIS device
  /// stays signed in. That is what SignOutScope.others means, and it is the
  /// difference between a safety action and locking yourself out with it.
  Future<void> _signOutOtherDevices() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out of other devices?'),
        content: const Text(
          'Any other phone still signed into this account — one you lost, '
          'sold or replaced — will be signed out and will need your password '
          'to get back in. This phone stays signed in.',
          style: TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign them out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SupabaseRepository.signOutOtherDevices();
      _toast('Signed out everywhere else.');
    } catch (e) {
      _toast(friendlyAuthError(e));
    }
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
        title: Text(switch (widget.page) {
          SettingsPage.root => 'Settings',
          SettingsPage.profile => 'Your profile',
          SettingsPage.notifications => 'Notifications',
          SettingsPage.account => 'Account & data',
        },),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            // A newer sideload build is published — the on-demand way to update,
            // beside the once-a-launch prompt. Hidden on the play build and when
            // nothing newer exists (UpdateService.available).
            if (UpdateService.available) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.system_update,
                    color: MilesColors.ember,),
                title: const Text('Update available'),
                subtitle: Text(
                  ReleaseGate.latestVersionName != null
                      ? 'Install version ${ReleaseGate.latestVersionName}'
                      : 'Install the latest version',
                ),
                onTap: () => showUpdateSheet(context),
              ),
              const SizedBox(height: 8),
            ],
            ...switch (widget.page) {
              SettingsPage.root => _rootGroups(profile, partner, isModest),
              SettingsPage.profile => _profilePage(profile, partner),
              SettingsPage.notifications => _notificationsPage(),
              SettingsPage.account => _accountPage(),
            },
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  /// The root screen: a profile card and five groups.
  ///
  /// This replaced fourteen `_SectionHeader`s over bare ListTiles. The change
  /// that makes it fit is not the cards — it is putting each setting's CURRENT
  /// VALUE at the end of its own row ("On", "Asia/Karachi", "Backup on"), so a
  /// row explains itself without a header above it. Recovered from build 52;
  /// see docs/guides/BUILD-52-AUDIT.md.
  List<Widget> _rootGroups(dynamic profile, dynamic partner, bool isModest) => [
        _ProfileCard(
          name: profile?.displayName as String? ?? '',
          pairState: partner == null
              ? 'Not linked yet. Pair with your partner to share this app'
              : 'Paired with ${partner.displayName}',
          avatarUrl: _localAvatarUrl ?? profile?.avatarUrl as String?,
          onTap: () => context.push('/app/settings/profile'),
        ),
        _SettingsGroup(children: [
          _SettingsRow(
            icon: Icons.notifications_none,
            title: 'Notifications',
            // The truth, not a decoration. This row said "On" unconditionally,
            // which is the one thing it must never say when they are off.
            value: _notif.appBlocked
                ? 'Off'
                : _notif.anyBlocked
                    ? 'Some blocked'
                    : _notif.appEnabled == null
                        ? null
                        : 'On',
            onTap: () => context.push('/app/settings/notifications'),
          ),
          const _SettingsRow(
            icon: Icons.translate,
            title: 'Content language',
            subtitle: 'Games in English',
            trailing: LanguageToggle(),
          ),
          _SettingsRow(
            icon: Icons.schedule,
            title: 'Timezone',
            subtitle: 'Used for the countdown & sky',
            value: profile?.timezone.replaceAll('_', ' ') as String? ?? '—',
            onTap: _changeTimezone,
          ),
        ],),
        _SettingsGroup(
          label: 'Appearance',
          children: [
            _SettingsRow(
              icon: Icons.palette_outlined,
              title: 'How this app looks',
              subtitle: 'The icon and name shown on your phone',
              value: 'Miles',
              onTap: () => context.push('/app/disguise'),
            ),
          ],
        ),
        _SettingsGroup(
          label: 'Privacy & security',
          children: [
            _SettingsRow(
              icon: Icons.fingerprint,
              title: 'App lock',
              subtitle: 'Require fingerprint / face / PIN to open Miles',
              trailing: Switch(
                value: _appLock,
                onChanged: _toggleAppLock,
                activeThumbColor: MilesColors.ember,
              ),
            ),
            _SettingsRow(
              icon: Icons.pin_outlined,
              title: 'Security code',
              // The STATE, not a description of the feature: a row that only
              // says what the code is cannot tell the couple whether they have
              // ever used it, and for most couples the answer is no.
              subtitle: switch (_codeVerified) {
                true => 'Compared with your partner — this key is verified',
                false => 'Not compared yet — read it aloud together once',
                null => 'A code you both compare to verify your encryption',
              },
              onTap: () =>
                  showSecurityCodeDialog(context, partnerId: partner?.id as String?),
            ),
            _SettingsRow(
              icon: Icons.location_on_outlined,
              title: 'Location sharing',
              subtitle: _locationProblem ?? 'Only your partner can ever see this',
              value: _locationLabel,
              onTap: _locationProblem == null
                  ? _changeLocationSharing
                  : _fixLocationSharing,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Text(_error!,
                    style: const TextStyle(color: MilesColors.blush),),
              ),
            _SettingsRow(
              icon: Icons.favorite_border,
              title: 'Closer',
              subtitle: isModest
                  ? 'Hidden. Reveal for both partners.'
                  : 'Visible to both of you.',
              trailing: Switch(
                value: !isModest,
                onChanged: _busy ? null : _toggleModestMode,
                activeThumbColor: MilesColors.ember,
              ),
            ),
          ],
        ),
        _SettingsGroup(
          label: 'Support',
          children: [
            _SettingsRow(
              icon: Icons.help_outline,
              title: 'Help & FAQ',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const FaqScreen()),
              ),
            ),
            _SettingsRow(
              icon: Icons.flag_outlined,
              title: 'Report a problem',
              subtitle: 'Something here that should not be',
              // Same target choice the flat screen made: a report with no
              // partner is about the app, not about a person who is not there.
              onTap: () => showReportSheet(
                context,
                target: partner == null
                    ? ReportTarget.appContent
                    : ReportTarget.partner,
              ),
            ),
          ],
        ),
        _SettingsGroup(
          label: 'Your data',
          children: [
            _SettingsRow(
              icon: Icons.manage_accounts_outlined,
              title: 'Account & data',
              subtitle: 'Email, export, sign out, delete',
              value: _escrowMissing ? 'Backup off' : 'Backup on',
              onTap: () => context.push('/app/settings/account'),
            ),
            _SettingsRow(
              icon: Icons.info_outline,
              title: 'About',
              value: '${ReleaseGate.versionName} (${ReleaseGate.buildNumber})',
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => const Dialog(
                  backgroundColor: MilesColors.surface1,
                  child: _AboutCard(),
                ),
              ),
            ),
          ],
        ),
      ];

  List<Widget> _profilePage(dynamic profile, dynamic partner) => [
        Center(
          child: Semantics(
            button: true,
            enabled: !_changingAvatar,
            label: 'Change profile photo',
            onTap: _changingAvatar ? null : _changeAvatar,
            excludeSemantics: true,
            child: EmberPress(
              onTap: _changingAvatar ? null : _changeAvatar,
              child: _AvatarEditor(
                url: _localAvatarUrl ?? profile?.avatarUrl as String?,
                name: profile?.displayName as String? ?? '',
                busy: _changingAvatar,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
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
        const SizedBox(height: 22),
        if (partner != null) ...[
          _SettingsGroup(
            label: 'Partner',
            children: [
              _SettingsRow(
                icon: Icons.favorite,
                title: partner.displayName as String,
                subtitle: partner.timezone.replaceAll('_', ' ') as String,
              ),
              // The sheet owns every word of the unpair ceremony, including
              // the confirmation. A row that restates it here is the copy
              // severance_confirm_test was written to keep out.
              _SettingsRow(
                icon: Icons.link_off,
                title: 'Remove partner',
                onTap: _busy ? null : _removePartner,
              ),
            ],
          ),
        ],
        _SettingsGroup(children: [
          _SettingsRow(
            icon: Icons.badge_outlined,
            title: 'About you',
            subtitle: 'Gender',
            value: profile?.gender == 'female'
                ? 'Female'
                : profile?.gender == 'male'
                    ? 'Male'
                    : 'Not set',
            onTap: _changeGender,
          ),
        ],),
      ];

  List<Widget> _notificationsPage() => [
        // Said at the top, because every row below is a lie while this is
        // true: they all open the right pages and none of them can ring.
        if (_notif.appBlocked)
          _SettingsGroup(children: [
            _SettingsRow(
              icon: Icons.notifications_off_outlined,
              title: 'Alerts are off for this app, so nothing below can '
                  'reach you.',
              value: 'Go to settings',
              onTap: FsiPermission.openSettings,
            ),
          ],)
        else if (_notif.appEnabled == null)
          const _SettingsGroup(children: [
            _SettingsRow(
              icon: Icons.help_outline,
              title: "Your phone didn't say how these are set. The rows still "
                  'open the right pages.',
            ),
          ],),
        _SettingsGroup(children: [
          FutureBuilder<bool>(
            future: FsiPermission.canUse(),
            builder: (context, snap) {
              // Only ONE of the three states offers a tap. A row that opens a
              // settings page this phone does not have is worse than a row
              // that says so.
              final supported = snap.data;
              return _SettingsRow(
                icon: Icons.fullscreen,
                title: 'Full-screen alerts',
                subtitle: supported == false
                    ? 'This phone has no full-screen alert setting.'
                    : 'Let a call light up your screen while the phone '
                        'is locked',
                onTap:
                    supported == false ? null : FsiPermission.openSettings,
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: ContactPause.active,
            builder: (context, paused, _) => _SettingsRow(
              icon: Icons.notifications_paused_outlined,
              title: 'Pause notifications',
              subtitle: paused
                  ? _pauseSubtitle()
                  : 'Quiet for a while, without ending anything',
              onTap: () => showContactPauseSheet(context),
            ),
          ),
        ],),
        _SettingsGroup(
          label: 'Sound & vibrate',
          children: [
            ValueListenableBuilder<int>(
              valueListenable: ReleaseGate.revision,
              builder: (context, _, __) {
                final killed = ReleaseGate.uiSoundKilled;
                return _SettingsRow(
                  icon: Icons.music_note_outlined,
                  title: 'Sounds',
                  subtitle: killed
                      ? 'Turned off remotely for this release.'
                      : 'Soft sounds for moments — sending, sealing, '
                          'breathing. Vibration is separate and stays on.',
                  trailing: Switch(
                    value: !killed && MilesSound.enabled,
                    onChanged: killed ? null : _toggleSounds,
                    activeThumbColor: MilesColors.ember,
                  ),
                );
              },
            ),
          ],
        ),
        _SettingsGroup(
          label: 'Channels',
          children: [
            for (final (String id, String title, String subtitle) in const [
              (kReachChannelId, 'Reach alerts',
                  'The buzz when your partner reaches for you'),
              (kCallChannelId, 'Incoming calls', 'How a call rings on this phone'),
              (kMsgChannelId, 'Messages', 'New chat messages'),
              (kCareChannelId, 'Reminders',
                  'Care reminders, rituals and memory proposals'),
              (kQuietChannelId, 'Silent delivery',
                  'Alerts that arrive without sound on quiet covers'),
              (kCallServiceChannelId, 'Ongoing calls',
                  'The quiet notice shown while a call is running'),
              (kTimerChannelId, 'Timer cover',
                  'The countdown finishing in the Timer cover'),
            ])
              _SettingsRow(
                icon: Icons.tune,
                title: title,
                subtitle: subtitle,
                value: _notif.blocked.contains(id) ? 'Blocked' : null,
                onTap: () =>
                    NotificationChannelSettings.open(context, channelId: id),
              ),
          ],
        ),
      ];

  List<Widget> _accountPage() => [
        _SettingsGroup(children: [
          _SettingsRow(
            icon: Icons.backup_outlined,
            title: 'Recovery backup',
            subtitle: _escrowMissing
                ? 'Off — without it, a reinstall cannot read your history'
                : 'On',
            value: _escrowMissing ? 'Backup off' : 'Backup on',
            onTap: _escrowMissing ? _fixEscrow : null,
          ),
          _SettingsRow(
            icon: Icons.download_outlined,
            title: 'Export your data',
            subtitle: 'A copy of everything, readable offline',
            onTap: () => context.push('/app/settings/export'),
          ),
          _SettingsRow(
            icon: Icons.mail_outline,
            title: 'Change email',
            onTap: _changeEmail,
          ),
        ],),
        _SettingsGroup(children: [
          _SettingsRow(
            icon: Icons.devices_outlined,
            title: 'Sign out of other devices',
            subtitle: 'This phone stays signed in',
            onTap: _signOutOtherDevices,
          ),
          _SettingsRow(
            icon: Icons.logout,
            title: 'Sign out',
            onTap: _signOut,
          ),
          _SettingsRow(
            icon: Icons.delete_forever_outlined,
            title: 'Delete account',
            subtitle: 'Permanently erases your data',
            onTap: _busy ? null : _deleteAccount,
          ),
        ],),
      ];
}

/// Who made this, and which build you are actually holding.
///
/// The version is read from [ReleaseGate] rather than typed here. The line it
/// replaces said `v0.1.0` in a build numbered 30 — a hardcoded string in a
/// footer nobody looks at is exactly the thing that drifts, and it is also the
/// first thing anyone reports a bug with.
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: MilesColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Masthead. Generous top padding and the tagline directly under the
          // wordmark, so the card opens with the app's name rather than with a
          // table — the old one led with a key/value grid and read like a
          // diagnostics dump.
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wordmark(size: 24),
                SizedBox(height: 8),
                Text(
                  'Feel close, even from here.',
                  style: TextStyle(
                    color: MilesColors.taupe,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: MilesColors.hairline),

          // The facts. One rhythm: label left in faint, value right in cream,
          // baseline-aligned, each row the same height. A fixed 104px gutter
          // was what made the old one look ragged — 'Latest available' wrapped
          // and nothing else did.
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Column(
              children: [
                _AboutRow(label: 'Developed by', value: 'RD Developers'),
                _AboutRow(
                  label: 'Version',
                  value: '${ReleaseGate.versionName} '
                      '(${ReleaseGate.buildNumber})',
                ),
              ],
            ),
          ),
          // Split out of the const block because it reads runtime state. What
          // the release check actually came back with: "no prompt appeared" was
          // three separate causes over two days — a stale snapshot, a channel
          // flag, and a version already current — and from the outside all
          // three look identical. This says which.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _AboutRow(
              label: 'Latest',
              value: ReleaseGate.apkUrl == null
                  ? 'not reachable'
                  : ReleaseGate.latestBuild > ReleaseGate.buildNumber
                      ? '${ReleaseGate.latestBuild} · update ready'
                      : 'up to date',
              accent: ReleaseGate.latestBuild > ReleaseGate.buildNumber,
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, thickness: 1, color: MilesColors.hairline),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  // The honest split, and it has to stay honest: the Terms link
                  // is directly below and says the same thing. Chat text and
                  // media are stored where the operator could read them; the
                  // vault, memory threads and wish jar are sealed on this phone
                  // with a key the server never holds. Claiming all of it was
                  // encrypted was a sentence this screen contradicted with its
                  // own second link.
                  'Your vault, memory threads and wish jar are sealed on this '
                  'phone with a key we never hold. Chat and its media are not '
                  '\u2014 they are stored, and never read.',
                  style: TextStyle(
                    color: MilesColors.taupe,
                    fontSize: 12.5,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 14),
                // Wrap, not Row: five links overflow a narrow phone.
                Wrap(
                  spacing: 20,
                  runSpacing: 10,
                  children: [
                    // In-app, not a URL: opening Chrome throws the user out of
                    // an app whose launcher identity may be a cover, and the
                    // terms have to be readable with no connection because they
                    // gate the app on first run. The FAQ follows the same rule.
                    _AboutLink(
                      label: 'FAQ',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const FaqScreen(),
                        ),
                      ),
                    ),
                    _AboutLink(
                      label: 'Terms',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TermsScreen(readOnly: true),
                        ),
                      ),
                    ),
                    _AboutLink(
                      label: 'Privacy Policy',
                      onTap: () => _openPrivacyPolicy(context),
                    ),
                    // The fourth document, and the one Play blocks publishing a
                    // social app without. It was written and hosted while this
                    // card still listed three, so the standards existed and the
                    // app never pointed at them — findable by a reviewer given
                    // the Console URL, and by nobody actually using the app.
                    //
                    // A URL rather than a screen, unlike the three above: it is
                    // the document Google, a platform or a police force is told
                    // to read, and that audience is not holding this phone.
                    _AboutLink(
                      label: 'Child Safety',
                      onTap: () => _openLegalPage(context, milesCsaeUrl),
                    ),
                    // The disclosure route, and the reason it is here rather
                    // than only in security.txt: a researcher holding a
                    // sideloaded APK has no issue tracker and no store thread
                    // to write into, so without this row the only way to reach
                    // us is to guess an address. A URL for the same reason as
                    // the row above.
                    _AboutLink(
                      label: 'Report a security issue',
                      onTap: () => _openLegalPage(context, milesSecurityUrl),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// The policy is written (docs/legal, web/privacy-policy.html) and not yet
  /// hosted, so [milesPrivacyPolicyUrl] is empty. Say that, rather than open a
  /// browser onto a 404 and leave the user wondering what else is missing.
  Future<void> _openPrivacyPolicy(BuildContext context) =>
      _openLegalPage(context, milesPrivacyPolicyUrl);

  /// Opens one of the hosted legal documents in a browser.
  ///
  /// An empty constant means "not published", which is a real state — inventing
  /// a URL here would ship a link that 404s in front of whoever followed it.
  /// Say so rather than opening a dead page.
  Future<void> _openLegalPage(BuildContext context, String href) async {
    final url = Uri.tryParse(href);
    if (href.isEmpty || url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That document is not published yet.')),
      );
      return;
    }
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open that link.")),
        );
      }
    }
  }
}

class _AboutLink extends StatelessWidget {
  const _AboutLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A bare GestureDetector around 12px text was ~15dp of target and reached
    // TalkBack as plain words with no role — and two of these five front the
    // Privacy Policy and Child Safety pages, the documents this app is least
    // allowed to make unreachable. One node, announced as a link, named by its
    // own text. The tap lives on the Semantics itself: excludeSemantics drops
    // the detector's, and without it a screen reader is handed a link it
    // cannot open. The box puts a 48dp floor under the finger — the glyphs
    // keep their size but each link's ROW grows to 48dp tall, which is the
    // point, not a side effect; opaque, because deferToChild hands the
    // padding back.
    return Semantics(
      link: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Align(
            // widthFactor pins the Align to its text: inside the Wrap the
            // incoming width is the whole card, and an unfactored Align takes
            // it all — four links, four full-width runs.
            widthFactor: 1,
            child: Text(
              label,
              style: const TextStyle(
                color: MilesColors.gilt,
                fontSize: 12,
                decoration: TextDecoration.underline,
                decorationColor: MilesColors.gilt,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.label,
    required this.value,
    this.accent = false,
  });

  final String label;
  final String value;

  /// Draws the value in ember. Used for the one row that is an invitation
  /// rather than a fact — an update waiting to be installed.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        // Label and value share a baseline. The old row used a 104px SizedBox
        // and start-alignment, so a value that wrapped sat a line above its own
        // label and the column read as broken.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: const TextStyle(
                color: MilesColors.faint,
                fontSize: 12.5,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: accent ? MilesColors.ember : MilesColors.cream50,
                fontSize: 12.5,
                fontWeight: accent ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable round avatar with a camera badge (Issue 7 — profile photo, 1:1).
class _AvatarEditor extends StatelessWidget {
  const _AvatarEditor(
      {required this.url, required this.name, required this.busy,});
  final String? url;
  final String name;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: MilesColors.surface2,
            border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.3)),
          ),
          clipBehavior: Clip.antiAlias,
          child: busy
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : url == null
                  ? Center(
                      child: Text(initial,
                          style: const TextStyle(
                              color: MilesColors.cream50, fontSize: 34,),),)
                  : SignedImage(
                      bucket: chatBucket,
                      value: url,
                      placeholder: Center(
                          child: Text(initial,
                              style: const TextStyle(
                                  color: MilesColors.cream50, fontSize: 34,),),),),
        ),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: MilesColors.blush,
          ),
          child: const Icon(Icons.camera_alt,
              size: 15, color: MilesColors.cream50,),
        ),
      ],
    );
  }
}

/// A group of rows in one rounded card, the way a platform settings app does
/// it: hairline rules between rows, inset past the icon column so a rule
/// starts where the text does.
///
/// The fill is opaque on purpose. This is a surface you read on and the ember
/// field behind it moves; a translucent one is an animation playing under your
/// settings, which repo_hygiene_test fails the build for.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children, this.label});

  /// Null for the first group, which carries no header — the screen opens on
  /// rows rather than on a word.
  final String? label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Padding(
          padding: EdgeInsets.only(left: 54),
          child: Divider(height: 1, thickness: 1, color: MilesColors.hairline),
        ));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) _SectionHeader(label: label!),
          DecoratedBox(
            decoration: BoxDecoration(
              color: MilesColors.surface1,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: MilesColors.hairline),
            ),
            child: Column(children: rows),
          ),
        ],
      ),
    );
  }
}

/// One settings row: icon, title, optional subtitle, and either a value or a
/// control at the end.
///
/// Putting the CURRENT STATE at the end of the row — "On", "Asia/Karachi",
/// "Midnight Boudoir" — is what lets one screen carry this many settings
/// without a header above every single one.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Current state, shown at the end of the row.
  final String? value;

  /// A control instead of a value — a switch, a segmented toggle.
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 22, color: MilesColors.gilt),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: const TextStyle(
                        color: MilesColors.taupe,
                        fontSize: 12.5,
                        height: 1.3,
                      ),),
                ],
              ],
            ),
          ),
          if (value != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(value!,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: MilesColors.taupe,
                      fontSize: 13,
                    ),),
              ),
            ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: trailing,
            ),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child:
                  Icon(Icons.chevron_right, size: 20, color: MilesColors.gilt),
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return EmberPress(onTap: onTap, child: row);
  }
}

/// The hero card the screen opens on: who you are, and whether the couple
/// exists yet. It answers "is this thing connected" before any setting does.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.name,
    required this.pairState,
    required this.avatarUrl,
    required this.onTap,
  });

  final String name;
  final String pairState;
  final String? avatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: EmberPress(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: MilesColors.surface1,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: MilesColors.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: MilesColors.surface2,
                    border: Border.all(color: MilesColors.hairline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  alignment: Alignment.center,
                  // SignedImage, never NetworkImage: avatars are PATHS in the
                  // private couple_media bucket. Handing the raw path to
                  // NetworkImage threw ArgumentError on every Settings open —
                  // the build-59 client_errors named it.
                  child: avatarUrl != null
                      ? SignedImage(
                          bucket: 'couple_media',
                          value: avatarUrl,
                          width: 62,
                          height: 62,
                          thumb: true,
                        )
                      : Text(
                          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                          style: const TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name.isEmpty ? 'Your profile' : name,
                          style: const TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),),
                      const SizedBox(height: 3),
                      Text(pairState,
                          style: const TextStyle(
                            color: MilesColors.taupe,
                            fontSize: 13.5,
                          ),),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: MilesColors.gilt),
              ],
            ),
          ),
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
        .where((tz) => tz
            .toLowerCase()
            .contains(_query.toLowerCase().replaceAll(' ', '_')),)
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
              style: Theme.of(context).textTheme.titleLarge,),
          const SizedBox(height: 12),
          TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            style: const TextStyle(color: MilesColors.cream50),
            decoration: const InputDecoration(
                hintText: 'Search a city…', prefixIcon: Icon(Icons.search),),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: filtered.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(filtered[i].replaceAll('_', ' '),
                    style: const TextStyle(color: MilesColors.cream50),),
                onTap: () => Navigator.pop(context, filtered[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Proof-of-owner fallback for phones with no screen lock enrolled — the
/// reconnect sheet's dialog, worn by the emergency exit.
class _EmergencyPasswordDialog extends StatefulWidget {
  const _EmergencyPasswordDialog();

  @override
  State<_EmergencyPasswordDialog> createState() =>
      _EmergencyPasswordDialogState();
}

class _EmergencyPasswordDialogState extends State<_EmergencyPasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MilesColors.surface1,
      title: const Text('Your password',
          style: TextStyle(color: MilesColors.cream50, fontSize: 16),),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Just to be sure it’s you.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 13),),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: MilesColors.cream50),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel',
              style: TextStyle(color: MilesColors.taupe),),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: MilesColors.ember),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
