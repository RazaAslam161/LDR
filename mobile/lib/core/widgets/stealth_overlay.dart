import 'package:flutter/material.dart';

/// Controls the quick-cover stealth scrim from anywhere.
final ValueNotifier<bool> stealthActive = ValueNotifier<bool>(false);

/// True while a screen owns the whole touchscreen for itself — the move
/// recorder, whose owner may hold the top-right corner on purpose. The
/// long-press zone below and the panic detector both stand down for it.
final ValueNotifier<bool> stealthSuppressed = ValueNotifier<bool>(false);

/// App-wide stealth layer: an invisible 48×48 LONG-PRESS zone in the top-right
/// corner that raises an innocent "Syncing news" scrim over the ENTIRE app.
/// Dismiss by tapping the scrim (or volume-down).
///
/// Long-press (not tap) + translucent hit-testing is deliberate: it must NOT
/// swallow single taps on the real AppBar actions that live in the same
/// top-right corner (chat overflow menu, call buttons). A quick tap passes
/// through to those buttons; only a deliberate ~0.5s hold raises the cover.
///
/// Lives INSIDE MaterialApp (so MediaQuery/Directionality exist) — drop it into
/// the app-wide builder Stack wrapped in a Positioned.fill so it fills the
/// screen and its own Positioned children resolve correctly.
class StealthLayer extends StatelessWidget {
  const StealthLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Invisible, always-present long-press zone — top-right corner, 48×48.
        // No visual indicator of any kind. Translucent so single taps fall
        // through to any real button underneath.
        ValueListenableBuilder<bool>(
          valueListenable: stealthSuppressed,
          builder: (_, suppressed, __) => suppressed
              ? const SizedBox.shrink()
              : Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: 4,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onLongPress: () => stealthActive.value = true,
                    child: const SizedBox(width: 48, height: 48),
                  ),
                ),
        ),
        // The cover scrim — instant (no fade), tap anywhere to dismiss.
        ValueListenableBuilder<bool>(
          valueListenable: stealthActive,
          builder: (_, active, __) => active
              ? Positioned.fill(child: _StealthScrim(onDismiss: () {
                  stealthActive.value = false;
                },),)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _StealthScrim extends StatelessWidget {
  const _StealthScrim({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      // Solid near-opaque light surface (NOT a BackdropFilter — it renders
      // unpredictably over FLAG_SECURE on some devices).
      //
      // Deliberately branded as NOTHING. This used to draw a white tile with
      // `G≡` in #1A73E8 — Google's own brand blue — a spinner in the same blue
      // and the words "Syncing your news...", which is an imitation of a Google
      // product and squarely inside Play's Impersonation policy ("imitate the
      // look and feel of another app or brand"). Reviewed by Google, on a cover
      // feature Google already looks hard at, that is not a risk worth a
      // colour. A plain neutral progress screen is just as unremarkable to
      // anyone glancing at the phone, which is the whole job, and it copies
      // nobody. Do not put a recognisable mark, wordmark or brand colour back
      // in here.
      child: ColoredBox(
        color: const Color(0xFFF4F4F5),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: const Color(0xFFE4E4E7), width: 0.5),
                ),
                child: const Center(
                  child: Icon(
                    Icons.sync_rounded,
                    size: 26,
                    color: Color(0xFF71717A),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Color(0xFF71717A)),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Syncing…',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF71717A),
                  fontFamily: 'Inter',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
