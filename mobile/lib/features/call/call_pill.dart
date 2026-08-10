import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/call/call_controller.dart';

/// A floating "tap to return to call" pill shown over the whole app while a
/// call is running but minimised — so you can keep using Miles during a call.
class CallPill extends ConsumerWidget {
  const CallPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);
    final active =
        call.state == CallState.connected || call.state == CallState.calling;
    if (!active || !call.minimized) return const SizedBox.shrink();

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: () {
                call.setMinimized(false);
                ref.read(routerProvider).push('/call');
              },
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                decoration: BoxDecoration(
                  color: MilesColors.sage,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 10,),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(call.isVideo ? Icons.videocam : Icons.call,
                        color: Colors.white, size: 18,),
                    const SizedBox(width: 8),
                    Text(
                      call.state == CallState.calling
                          ? 'Calling ${call.peerName ?? ''}… tap to return'
                          : 'On call · tap to return',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: call.hangup,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: Colors.red,),
                        child: const Icon(Icons.call_end,
                            color: Colors.white, size: 16,),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
