import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';

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
    setState(() => _applying = true);

    final messenger = ScaffoldMessenger.of(context);
    final ok = await DisguiseService.apply(choice);
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

  Future<void> _keepAsIs() async {
    await DisguiseService.markChosen();
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    // Settings links here on every channel; only this screen knows whether
    // there is anything behind the link. On the play channel there is not —
    // the app ships one launcher entry under its own name, and a list of nine
    // invented identities is the misrepresentation that channel avoids.
    if (!DisguiseService.enabled) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('How this app looks')),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Text(
            'This version of the app appears under its own name and icon. '
            'There is nothing to change here.',
            style: GoogleFonts.inter(
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
                style: GoogleFonts.inter(
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
                "Android's own Settings › Apps list keeps calling this app "
                '"News" whichever disguise you pick. That name is fixed when '
                'the app is installed and no app can change it afterwards.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
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
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: MilesColors.cream50,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profile.blurb,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: MilesColors.taupe,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // The one thing nothing else will remind you of. A disguise
                    // whose door you cannot remember is an app you cannot open.
                    Text(
                      'Way in — ${profile.entry}',
                      style: GoogleFonts.inter(
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
