import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/features/call/call_controller.dart';

/// Whether the diagnostic readout is showing. Outside the widget so it survives
/// the call screen being minimised to the pill and reopened.
final ValueNotifier<bool> _showStats = ValueNotifier<bool>(false);

class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);
    final partner = ref.watch(sessionProvider).partner;

    // Leave the screen once the call settles back to idle.
    ref.listen(callControllerProvider, (_, __) {
      if (call.state == CallState.idle && context.mounted) {
        // Say WHY before the screen disappears. Without this the whole
        // failure is a flash: the call screen appears, the route pops, and
        // the user is told nothing — which reads as "the app is broken" and
        // is exactly how two months of call failures were reported.
        final err = call.takeLastError();
        if (err != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err), duration: const Duration(seconds: 5)),
          );
        }
        if (context.canPop()) context.pop();
      }
    });

    final connected = call.state == CallState.connected;
    final ringing = call.state == CallState.ringing;
    final calling = call.state == CallState.calling;
    final video = call.isVideo;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && call.state != CallState.idle) call.setMinimized(true);
      },
      child: Scaffold(
        backgroundColor: MilesColors.night,
        body: Stack(
          children: [
            // Long-press anywhere to reveal what the call is really doing.
            // Hidden by default: this is a diagnostic, not something a partner
            // should ever see mid-call.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPress: () => _showStats.value = !_showStats.value,
              ),
            ),
            // Remote video (full screen) — video calls only, once connected.
            if (connected && video)
              Positioned.fill(
                // A shared display is portrait-tall and full of small text;
                // cropping it to fill would shave the edges off the thing they
                // are both looking at.
                child: RTCVideoView(call.remoteRenderer,
                    objectFit: call.remoteScreen
                        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,),
              )
            else
              const Positioned.fill(
                  child: ColoredBox(color: MilesColors.night),),

            // The numbers that tell a capture problem from an encoder problem
            // from a network problem — they look identical on screen otherwise.
            ValueListenableBuilder<bool>(
              valueListenable: _showStats,
              builder: (context, show, _) {
                final st = call.stats;
                if (!show) return const SizedBox.shrink();
                return Positioned(
                  top: MediaQuery.paddingOf(context).top + 8,
                  left: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6,),
                      decoration: BoxDecoration(
                        // A scrim over the remote video feed, not a panel:
                        // these numbers have to stay readable against whatever
                        // the other camera happens to be pointing at.
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        st?.line ?? 'waiting for first sample…',
                        style: const TextStyle(
                          color: Color(0xFF7CFF9B),
                          fontSize: 10,
                          fontFamily: 'monospace',
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

            // Said out loud, because the person who needs to know is usually in
            // another country with no cable and no logcat. Without a relay,
            // two people on different networks cannot connect at all — and
            // every symptom of that reads as "the call just didn't work".
            // relayKnown is tri-state: null means "not fetched yet", which
            // is not the same as "no relay" and must not accuse the network.
            if (CallController.relayKnown == false && (calling || ringing))
              Positioned(
                top: MediaQuery.paddingOf(context).top + 44,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8,),
                    decoration: BoxDecoration(
                      // Also a scrim over the video feed — a solid banner
                      // across a live call is worse than a legible one.
                      color: const Color(0xCC5A1A14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE0564B)),
                    ),
                    child: const Text(
                      'Calling may fail — no relay server available. '
                      'This usually means calls only work when both of you are '
                      'on the same wifi.',
                      style: TextStyle(
                        color: Color(0xFFFFD9D4),
                        fontSize: 11,
                        height: 1.35,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),

            // Voice centerpiece (or pre-connect state): avatar + name + status.
            if (!video || !connected)
              Align(
                alignment: const Alignment(0, -0.35),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Avatar(
                        url: partner?.avatarUrl,
                        name: call.peerName ?? 'Partner',),
                    const SizedBox(height: 20),
                    Text(call.peerName ?? 'Partner',
                        style: const TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 24,
                            fontWeight: FontWeight.w600,),),
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
                          color: MilesColors.taupe, fontSize: 15,),
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
                        color: MilesColors.gilt.withValues(alpha: 0.3),),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: RTCVideoView(call.localRenderer,
                      // Follows the actual camera. Pinned to true, the back
                      // camera showed the world reversed.
                      mirror: call.frontCamera,
                      // The preview is a thumbnail, so this is a big DOWNscale
                      // — 720p into ~120dp. medium adds mipmapping, which is
                      // what stops a downscale shimmering and looking cheap.
                      // Deliberately not applied to the remote view: that one
                      // UPscales, where mipmaps do nothing and would only
                      // soften it further.
                      filterQuality: FilterQuality.medium,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,),
                ),
              ),

            // Minimize (keep call running, use the app).
            if (!ringing)
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down,
                        color: MilesColors.cream50, size: 30,),
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
                              onTap: call.decline,),
                          _RoundBtn(
                              icon: video ? Icons.videocam : Icons.call,
                              bg: MilesColors.sage,
                              label: 'Accept',
                              onTap: call.accept,),
                        ],
                      )
                    // Wrap, not Row: a video call now carries six controls at
                    // 60dp each, which is exactly 360dp — the full width of the
                    // commonest phone, and past it on anything narrower or on a
                    // handset whose owner raised Android's display size. A Row
                    // paints overflow stripes there; this drops the last button
                    // to a second line and is identical wherever it fits.
                    : Wrap(
                        alignment: WrapAlignment.spaceEvenly,
                        runSpacing: 16,
                        children: [
                          _RoundBtn(
                              icon: call.micOn ? Icons.mic : Icons.mic_off,
                              bg: MilesColors.surface2,
                              label: 'Mute',
                              onTap: call.toggleMic,),
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
                              onTap: () => call.setSpeaker(!call.speakerOn),),
                          if (video) ...[
                            _RoundBtn(
                                icon: call.camOn
                                    ? Icons.videocam
                                    : Icons.videocam_off,
                                bg: MilesColors.surface2,
                                label: 'Camera',
                                onTap: call.toggleCam,),
                            _RoundBtn(
                                icon: Icons.cameraswitch,
                                bg: MilesColors.surface2,
                                label: 'Flip',
                                onTap: call.switchCamera,),
                            // Connected-only: the swap needs a negotiated
                            // video sender to swap onto.
                            if (connected)
                              _RoundBtn(
                                  icon: call.sharingScreen
                                      ? Icons.stop_screen_share
                                      : Icons.screen_share,
                                  bg: call.sharingScreen
                                      ? MilesColors.ember
                                      : MilesColors.surface2,
                                  label: call.sharingScreen
                                      ? 'Stop'
                                      : 'Screen',
                                  onTap: () => call.sharingScreen
                                      ? call.stopScreenShare()
                                      : call.startScreenShare(),),
                          ],
                          _RoundBtn(
                              icon: Icons.call_end,
                              bg: Colors.red,
                              label: 'End',
                              onTap: call.hangup,),
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
            color: MilesColors.gilt.withValues(alpha: 0.35), width: 2,),
        boxShadow: [
          BoxShadow(
              color: MilesColors.blush.withValues(alpha: 0.3), blurRadius: 30,),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      // profiles.avatar_url holds a storage PATH, not a URL. Image.network on
      // it fails silently into the initial letter, so a partner with a photo
      // looked like a partner without one for the length of every call.
      child: url == null
          ? Center(
              child: Text(initial,
                  style: const TextStyle(
                      color: MilesColors.cream50, fontSize: 52,),),)
          : SignedImage(
              bucket: chatBucket,
              value: url,
              placeholder: Center(
                  child: Text(initial,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 52,),),),),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn(
      {required this.icon,
      required this.bg,
      required this.label,
      required this.onTap,});
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
            style: const TextStyle(color: MilesColors.taupe, fontSize: 11),),
      ],
    );
  }
}
