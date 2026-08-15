import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/call/call_controller.dart';

/// The call, minimised to a draggable window that floats over the whole app.
///
/// This replaces a pill that said "tap to return to call" — which meant that
/// while watching something together you could hear each other but not see
/// each other, and the call was a thing you left rather than a thing you were
/// still in.
///
/// It renders the controller's OWN [RTCVideoRenderer], not a copy. The
/// renderers live on the controller and outlive every screen, so moving the
/// call into this window touches no track, renegotiates nothing, and drops no
/// frame — the peer connection never learns the UI changed. That is the whole
/// reason this is cheap: it is a different place to draw the same texture.
class CallPip extends ConsumerStatefulWidget {
  const CallPip({super.key});

  @override
  ConsumerState<CallPip> createState() => _CallPipState();
}

class _CallPipState extends ConsumerState<CallPip> {
  /// Bottom-right by default: the top of the screen carries app bars and the
  /// left is where a back gesture starts.
  Offset? _pos;

  static const _w = 108.0;
  static const _h = 148.0;
  static const _margin = 12.0;

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    final active =
        call.state == CallState.connected || call.state == CallState.calling;
    if (!active || !call.minimized) return const SizedBox.shrink();

    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.paddingOf(context);
    final pos = _pos ??
        Offset(size.width - _w - _margin,
            size.height - _h - _margin - insets.bottom - 72,);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          final next = (_pos ?? pos) + d.delta;
          // Clamped so it cannot be dragged off-screen and stranded — there is
          // no other way back to the call once the window is gone.
          _pos = Offset(
            next.dx.clamp(_margin, size.width - _w - _margin),
            next.dy.clamp(insets.top + _margin,
                size.height - _h - _margin - insets.bottom,),
          );
        }),
        onTap: () {
          call.setMinimized(false);
          ref.read(routerProvider).push('/call');
        },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          color: MilesColors.surface1,
          child: SizedBox(
            width: _w,
            height: _h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (call.isVideo && call.remoteRenderer.srcObject != null)
                  RTCVideoView(
                    call.remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                else
                  Center(
                    child: Icon(
                      call.isVideo ? Icons.videocam : Icons.call,
                      color: const Color(0xCCFBF8F4),
                      size: 28,
                    ),
                  ),
                // Controls that matter while watching something else: mute,
                // and — the important one — turning the camera off.
                //
                // Killing the outgoing video track is the single largest thing
                // either of them can do for playback quality. A call and a
                // 1080p stream contend for one uplink, and WebRTC's congestion
                // control responds by degrading ITSELF, so on a tight link the
                // call quietly gets worse while the video buffers anyway.
                // Camera off frees roughly a megabit and costs nothing they are
                // looking at — they are watching the film, not each other.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      // scrim over the video, so the controls stay readable
                      // against whatever the camera happens to be pointing at
                      color: Color(0x99000000),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _MiniButton(
                          icon: call.micOn ? Icons.mic : Icons.mic_off,
                          on: call.micOn,
                          onTap: call.toggleMic,
                        ),
                        if (call.isVideo)
                          _MiniButton(
                            icon: call.camOn
                                ? Icons.videocam
                                : Icons.videocam_off,
                            on: call.camOn,
                            onTap: call.toggleCam,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.on,
    required this.onTap,
  });

  final IconData icon;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Icon(
            icon,
            size: 16,
            color: on ? const Color(0xFFFBF8F4) : const Color(0xFFEF6F58),
          ),
        ),
      );
}
