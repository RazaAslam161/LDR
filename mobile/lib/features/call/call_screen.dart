import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/call/call_controller.dart';

class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);
    final partner = ref.watch(sessionProvider).partner;

    // Leave the screen once the call settles back to idle.
    ref.listen(callControllerProvider, (_, __) {
      if (call.state == CallState.idle && context.mounted) {
        if (context.canPop()) context.pop();
      }
    });

    final connected = call.state == CallState.connected;
    final ringing = call.state == CallState.ringing;
    final calling = call.state == CallState.calling;
    final video = call.isVideo;

    return PopScope(
      // Backing out doesn't end the call — it minimises it (pill returns you).
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && call.state != CallState.idle) call.setMinimized(true);
      },
      child: Scaffold(
        backgroundColor: MilesColors.night,
        body: Stack(
          children: [
            // Remote video (full screen) — video calls only, once connected.
            if (connected && video)
              Positioned.fill(
                child: RTCVideoView(call.remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              )
            else
              const Positioned.fill(
                  child: ColoredBox(color: MilesColors.night)),

            // Voice centerpiece (or pre-connect state): avatar + name + status.
            if (!video || !connected)
              Align(
                alignment: const Alignment(0, -0.35),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Avatar(
                        url: partner?.avatarUrl,
                        name: call.peerName ?? 'Partner'),
                    const SizedBox(height: 20),
                    Text(call.peerName ?? 'Partner',
                        style: const TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 24,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(
                      ringing
                          ? (video
                              ? 'Incoming video call…'
                              : 'Incoming voice call…')
                          : calling
                              ? 'Calling…'
                              : connected
                                  ? 'Voice call · connected'
                                  : '',
                      style: const TextStyle(
                          color: MilesColors.taupe, fontSize: 15),
                    ),
                  ],
                ),
              ),

            // Local preview — PIP when connected, full while calling (video only).
            if (video && (calling || connected))
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
                      // Follows the actual camera. Pinned to true, the back
                      // camera showed the world reversed.
                      mirror: call.frontCamera,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),

            // Minimize (keep call running, use the app).
            if (!ringing)
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down,
                        color: MilesColors.cream50, size: 30),
                    tooltip: 'Minimize',
                    onPressed: () {
                      call.setMinimized(true);
                      if (context.canPop()) context.pop();
                    },
                  ),
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
                              icon: video ? Icons.videocam : Icons.call,
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
                          // Also the only way back to a headset connected
                          // after the call started — turning the speaker off
                          // re-scans and prefers bluetooth, then wired, then
                          // the earpiece.
                          _RoundBtn(
                              icon: call.speakerOn
                                  ? Icons.volume_up
                                  : Icons.phone_in_talk,
                              bg: MilesColors.surface2,
                              label: 'Speaker',
                              onTap: () => call.setSpeaker(!call.speakerOn)),
                          if (video) ...[
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
                          ],
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

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name});
  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    return Container(
      width: 132,
      height: 132,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: MilesColors.surface2,
        border: Border.all(
            color: MilesColors.gilt.withValues(alpha: 0.35), width: 2),
        boxShadow: [
          BoxShadow(
              color: MilesColors.blush.withValues(alpha: 0.3), blurRadius: 30),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? Center(
              child: Text(initial,
                  style: const TextStyle(
                      color: MilesColors.cream50, fontSize: 52)))
          : Image.network(url!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Center(
                  child: Text(initial,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 52)))),
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
