import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/closer/secure_screen.dart';

/// Tells the sharer, wherever they are in the app, that the screen in front of
/// them is not the screen their partner is getting.
///
/// Android blanks a FLAG_SECURE window in MediaProjection output, so walking
/// into the Vault, Memory Threads, Touch Trace, the Touch Map, the key-rewrap
/// screen, or a VIDEO page of the chat media viewer mid-share sends the partner
/// a black rectangle (the viewer's photo pages hold no flag —
/// media_viewer._applySecure). That is deliberate and stays — those screens
/// are secure on purpose. What was wrong is that it
/// happened silently: the partner saw a black screen indistinguishable from a
/// broken share, and the sharer had no way to know. Nothing here changes what
/// is captured; it changes only whether anyone is told.
///
/// Lives in the root Stack rather than on the call screen, because the whole
/// point is the moments when the call screen is NOT what is on top.
class ScreenShareBanner extends ConsumerWidget {
  const ScreenShareBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharing = ref.watch(
      callControllerProvider.select((c) => c.sharingScreen),
    );
    if (!sharing) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: SecureScreen.active,
      builder: (context, secure, _) {
        if (!secure) return const SizedBox.shrink();
        return Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          left: 12,
          right: 12,
          child: IgnorePointer(
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // A scrim over whatever screen it floats above, which is
                  // any of them: this lives in the root Stack precisely so it
                  // survives every route. Nearly opaque so the warning stays
                  // legible, and tinted rather than solid so it reads as a
                  // layer over the page rather than part of it.
                  color: const Color(0xE65A1A14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFE0564B)),
                ),
                child: const Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_off,
                          size: 14, color: Color(0xFFFFD9D4),),
                      SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          'This screen is hidden from your partner',
                          style: TextStyle(
                            color: Color(0xFFFFD9D4),
                            fontSize: 11.5,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
