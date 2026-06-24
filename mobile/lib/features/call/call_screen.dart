import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/call/call_controller.dart';

class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);

    // Leave the screen once the call settles back to idle.
    ref.listen(callControllerProvider, (_, __) {
      if (call.state == CallState.idle && context.mounted) {
        if (context.canPop()) context.pop();
      }
    });

    final connected = call.state == CallState.connected;
    final ringing = call.state == CallState.ringing;
    final calling = call.state == CallState.calling;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) call.hangup();
      },
      child: Scaffold(
        backgroundColor: MilesColors.night,
        body: Stack(
          children: [
            // Remote video (full screen) once connected.
            if (connected)
              Positioned.fill(
                child: RTCVideoView(call.remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              )
            else
              const Positioned.fill(
                  child: ColoredBox(color: MilesColors.night)),

            // Local preview — PIP when connected, full while calling.
            if (calling || connected)
              Align(
                alignment: connected ? Alignment.topRight : Alignment.center,
                child: Container(
                  margin: const EdgeInsets.all(16),
                  width: connected ? 110 : 220,
                  height: connected ? 160 : 320,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: MilesColors.gilt.withValues(alpha: 0.3)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: RTCVideoView(call.localRenderer,
                      mirror: true,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),

            // Status label
            if (!connected)
              Align(
                alignment: const Alignment(0, -0.55),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(call.peerName ?? 'Partner',
                        style: const TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 24,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(
                        ringing
                            ? 'Incoming video call…'
                            : calling
                                ? 'Calling…'
                                : '',
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 15)),
                  ],
                ),
              ),

            // Controls
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 44),
                child: ringing
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundBtn(
                              icon: Icons.call_end,
                              bg: Colors.red,
                              label: 'Decline',
                              onTap: call.decline),
                          _RoundBtn(
                              icon: Icons.videocam,
                              bg: MilesColors.sage,
                              label: 'Accept',
                              onTap: call.accept),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundBtn(
                              icon: call.micOn ? Icons.mic : Icons.mic_off,
                              bg: MilesColors.surface2,
                              label: 'Mute',
                              onTap: call.toggleMic),
                          _RoundBtn(
                              icon: call.camOn
                                  ? Icons.videocam
                                  : Icons.videocam_off,
                              bg: MilesColors.surface2,
                              label: 'Camera',
                              onTap: call.toggleCam),
                          _RoundBtn(
                              icon: Icons.cameraswitch,
                              bg: MilesColors.surface2,
                              label: 'Flip',
                              onTap: call.switchCamera),
                          _RoundBtn(
                              icon: Icons.call_end,
                              bg: Colors.red,
                              label: 'End',
                              onTap: call.hangup),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn(
      {required this.icon,
      required this.bg,
      required this.label,
      required this.onTap});
  final IconData icon;
  final Color bg;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: const TextStyle(color: MilesColors.taupe, fontSize: 11)),
      ],
    );
  }
}
