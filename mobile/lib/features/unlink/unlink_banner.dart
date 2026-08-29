import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ceremony's presence across the whole app.
///
/// Lives in the ROOT Stack beside ScreenShareBanner, so it survives every
/// screen change: a seven-day clock both people are living with must never
/// depend on which page happens to be open. Unlike that banner it is
/// TAPPABLE — the strip is the way back to the ceremony screen — so no
/// IgnorePointer, and the hit area is exactly the strip. It sits below
/// LockScreen and StealthLayer in the Stack, so covers hide it for free.
///
/// No Material ancestor up here: every Text carries TextDecoration.none.
class UnlinkBanner extends ConsumerWidget {
  const UnlinkBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch, not read: the delegate this rebuilds against must be the LIVE
    // router's, or a rebuilt provider would leave the banner listening to a
    // corpse.
    final router = ref.watch(routerProvider);
    return ValueListenableBuilder<UnlinkRow?>(
      valueListenable: UnlinkState.current,
      builder: (context, row, _) {
        if (row == null) return const SizedBox.shrink();
        return AnimatedBuilder(
          // Re-evaluates on navigation so the strip yields to the screen it
          // points at instead of doubling it.
          animation: router.routerDelegate,
          builder: (context, _) {
            final path =
                router.routerDelegate.currentConfiguration.uri.path;
            if (path == '/unlink') return const SizedBox.shrink();
            final left = row.endsAt.difference(ServerClock.now());
            final days = left.inDays;
            final label = left.isNegative
                ? 'Unlinking — the window has closed'
                : days > 0
                    ? 'Unlinking in $days ${days == 1 ? 'day' : 'days'} — '
                        'tap to see'
                    : 'Unlinking in ${left.inHours} h — tap to see';
            return Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 12,
              right: 12,
              child: GestureDetector(
                onTap: () => router.push('/unlink'),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Opaque, per the no-glassmorphism law: this strip is
                    // read over arbitrary pages.
                    color: MilesColors.surface1,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: MilesColors.gilt.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.link_off,
                            color: MilesColors.gilt, size: 16,),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: MilesColors.cream50,
                              fontSize: 13,
                              decoration: TextDecoration.none,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
