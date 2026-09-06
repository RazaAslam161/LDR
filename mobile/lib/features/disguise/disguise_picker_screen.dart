import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/app_lock_pin_sheet.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/disguise/entry/cover_entry_store.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';

/// Lets the user choose what this app looks like on their phone.
///
/// Shown once during onboarding and reachable afterwards from Settings. The
/// choice is the user's, deliberately: a single hardcoded disguise stops being a
/// disguise the moment the app is known, whereas a phone-by-phone choice has
/// nothing to recognise.
class DisguisePickerScreen extends ConsumerStatefulWidget {
  const DisguisePickerScreen({super.key, this.isOnboarding = false});

  /// Onboarding shows a skip affordance and pops on completion; Settings does
  /// not need the framing.
  final bool isOnboarding;

  @override
  ConsumerState<DisguisePickerScreen> createState() =>
      _DisguisePickerScreenState();
}

class _DisguisePickerScreenState extends ConsumerState<DisguisePickerScreen> {
  DisguiseProfile? _selected;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    DisguiseService.current().then((d) {
      if (mounted) setState(() => _selected = d);
    });
  }

  Future<void> _apply() async {
    final choice = _selected;
    if (choice == null || _applying) return;

    CoverEntryTrigger? entry;
    var keptExisting = false;
    if (choice.cover != DisguiseCover.none) {
      // A PIN before anything else. The app ships no door, so the only
      // public way in is the backup hold, and it lands on this PIN; a cover
      // with a move behind it may never be one a forgotten move locks. The
      // lock's own on/off switch stays the user's choice below.
      final hasPin = await AppLock.hasPin();
      if (!mounted) return;
      if (!hasPin && !await showAppLockPinSetup(context)) return;
      if (!mounted) return;
    }

    // App Lock is what puts a lock behind the owner's own move — with it on,
    // the move lands on the lock rather than straight in the app. It is not
    // what makes the way back EXIST, and treating it as a precondition made
    // the whole feature unavailable to anyone who does not want a second
    // lock on their own phone. So the trade is stated once, plainly, and the
    // choice is the user's.
    if (choice.cover != DisguiseCover.none && !await AppLock.isEnabled()) {
      if (!mounted) return;
      final goOn = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Apply without App Lock?'),
          content: Text(
            'With App Lock off, your move opens Miles directly — anyone who '
            'watches you do it is in. With App Lock on, your move lands on '
            'your lock instead.'
            '${widget.isOnboarding ? ' You can turn it on any time after '
                'setup.' : ''}',
            style: const TextStyle(color: MilesColors.taupe, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            if (!widget.isOnboarding)
              TextButton(
                // The router is captured before the pop: `ctx` belongs to the
                // dialog and is deactivated the moment it closes.
                onPressed: () {
                  final router = GoRouter.of(context);
                  Navigator.pop(ctx, false);
                  router.go('/app/settings');
                },
                child: const Text('Turn on App Lock'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply anyway'),
            ),
          ],
        ),
      );
      if (goOn != true || !mounted) return;
    }

    // The move itself, recorded on the cover it will open — before the alias
    // switch, which is where Android may force-stop the process. A cover
    // that already has one keeps it unless the owner wants a new one.
    if (choice.cover != DisguiseCover.none) {
      // The payload, not the mirror: `present` is also true for a record
      // that cannot be read, and offering to keep one of those applies a
      // cover whose only door is the public hold.
      if (await CoverEntryStore.load(choice.cover) != null) {
        if (!mounted) return;
        final answer = await _keepExistingMove(choice);
        // Dismissed is "never mind", not "throw my move away".
        if (answer == null || !mounted) return;
        keptExisting = answer;
      }
      if (!mounted) return;
      if (!keptExisting) {
        entry = await context.push<CoverEntryTrigger>(
          '/app/disguise/entry?cover=${choice.cover.name}',
        );
        if (entry == null || !mounted) return;
      }
    }

    // Applying a cover changes the launcher icon and name, and the way back in
    // is a move nobody but the owner knows — that is the point of it, and it
    // is also how someone locks themselves out of their own app. Naming the
    // consequence and the backup way in BEFORE the change is what separates a
    // feature the user chose from one that was done to them.
    if (choice.cover != DisguiseCover.none) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change how this app looks?'),
          content: Text(
            'Your home screen shows "${choice.label}", and this app leaves '
            "the share menu. Android's Settings › Apps, permission "
            'pop-ups and the top line of any notification still say Miles — '
            'no app can change those.\n\n'
            'Way back in — ${keptExisting ? 'the move already recorded for '
                'this cover' : 'the move you just recorded'}. Nothing else '
            'opens the cover, so practise it once before you put the phone '
            'down.',
            style: const TextStyle(color: MilesColors.taupe, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Change it'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _applying = true);

    final messenger = ScaffoldMessenger.of(context);
    final ok = await DisguiseService.apply(choice, entry: entry);
    if (!mounted) return;
    setState(() => _applying = false);

    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Couldn't change the icon on this device."),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    ref.invalidate(disguiseProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text('This app is now "${choice.label}".'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (widget.isOnboarding) unawaited(Navigator.of(context).maybePop());
  }

  Future<bool?> _keepExistingMove(DisguiseProfile choice) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Keep your ${choice.label} move?'),
        content: const Text(
          'You already recorded a way into this cover.',
          style: TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Record a new one'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Keep it'),
          ),
        ],
      ),
    );
  }

  Future<void> _keepAsIs() async {
    await DisguiseService.markChosen();
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    // Settings links here on every channel; only this screen knows whether
    // there is anything behind the link. Which channels have one is
    // build.gradle.kts's decision, not this file's — play ships the covers
    // too now (DISGUISE_ENABLED=true, disclosed in the listing) — so only the
    // runtime flag decides, and nothing here asserts a per-channel fact.
    if (!DisguiseService.enabled) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('How this app looks')),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Text(
            'This version of the app appears under its own name and icon. '
            'There is nothing to change here.',
            style: MilesType.inter(
              fontSize: 13,
              height: 1.5,
              color: MilesColors.taupe,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('How this app looks'),
        automaticallyImplyLeading: !widget.isOnboarding,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Text(
                'Pick what this app is called and what its icon looks like on '
                'your phone. Anyone glancing at your home screen sees only this.',
                style: MilesType.inter(
                  fontSize: 13,
                  height: 1.5,
                  color: MilesColors.taupe,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: DisguiseService.choices.length,
                itemBuilder: (context, i) {
                  final d = DisguiseService.choices[i];
                  final selected = d.aliasId == _selected?.aliasId;
                  return _DisguiseTile(
                    profile: d,
                    selected: selected,
                    onTap: _applying
                        ? null
                        : () => setState(() => _selected = d),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                'Your home screen may take a moment to refresh, and the app can '
                'close as the icon changes. That is Android doing the swap — '
                'open it again from the new icon.\n\n'
                "Android's own Settings › Apps list, permission pop-ups and "
                'the top line of any notification keep the name '
                '"${kPlainProfile.label}" whichever disguise you pick. That '
                'name is fixed when the app is installed and no app can '
                'change it afterwards.',
                textAlign: TextAlign.center,
                style: MilesType.inter(
                  fontSize: 11.5,
                  color: MilesColors.taupe.withValues(alpha: 0.8),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Row(
                children: [
                  if (widget.isOnboarding)
                    Expanded(
                      child: TextButton(
                        onPressed: _applying ? null : _keepAsIs,
                        child: const Text('Keep it as it is'),
                      ),
                    ),
                  if (widget.isOnboarding) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GlowButton(
                      label: 'Use this disguise',
                      color: MilesColors.blush,
                      loading: _applying,
                      onPressed: _applying ? null : _apply,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisguiseTile extends StatelessWidget {
  const _DisguiseTile({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final DisguiseProfile profile;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: MilesColors.surface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? MilesColors.blush
                  : MilesColors.gilt.withValues(alpha: 0.18),
              width: selected ? 1.6 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: profile.tint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(profile.icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.label,
                      style: MilesType.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: MilesColors.cream50,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profile.blurb,
                      style: MilesType.inter(
                        fontSize: 11.5,
                        color: MilesColors.taupe,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // The app prints no gesture here because it ships none:
                    // the door is the move the owner records on the next
                    // screen, and the backup hold is the reminder.
                    Text(
                      profile.cover == DisguiseCover.none
                          ? 'Opens straight into Miles.'
                          : 'Way in — a move you record next.',
                      style: MilesType.inter(
                        fontSize: 11,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: MilesColors.blush,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle,
                    color: MilesColors.blush, size: 22,),
            ],
          ),
        ),
      ),
    );
  }
}
