import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/call/call_face_strip.dart';
import 'package:miles/features/call/call_video.dart';

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
    // A share in either direction reshapes the whole screen the same way:
    // the share takes the big view, and every face moves into one strip.
    // (Both directions at once is impossible — the controller refuses a
    // share while one is being received.)
    final anyShare =
        connected && video && (call.sharingScreen || call.remoteScreen);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && call.state != CallState.idle) call.setMinimized(true);
      },
      child: Scaffold(
        backgroundColor: MilesColors.night,
        body: Stack(
          children: [
            // This screen paints every pixel; the root ember field under it
            // has no reason to keep ticking through a call.
            const EmberBackgroundHidden(),
            // Long-press anywhere to reveal what the call is really doing.
            // Hidden by default: this is a diagnostic, not something a partner
            // should ever see mid-call.
            Positioned.fill(
              key: const ValueKey('call-longpress'),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPress: () => _showStats.value = !_showStats.value,
              ),
            ),
            // Remote video (full screen) — video calls only, once connected.
            //
            // Keyed, like every other conditional child of this Stack. The
            // child count here varies with connected/ringing/video/relayKnown
            // while 14 notifyListeners() sites — including a 2-second stats
            // tick — rebuild the whole tree, so unkeyed children reconcile by
            // INDEX and a video view can be handed a slot that belonged to
            // something else.
            if (connected && video)
              Positioned.fill(
                key: const ValueKey('call-remote'),
                // The share — theirs or mine — takes the big view, and the
                // faces move to the strip rather than being displaced by it.
                child: call.sharingScreen
                    // My own share holds the big view. Live only when Android
                    // confirmed an app-scoped capture — a whole-display
                    // self-preview is a mirror inside the captured pixels
                    // (a tunnel), so that case gets the status panel.
                    ? call.appScopedShare
                        ? RTCVideoView(call.screenSelfRenderer,
                            key: const ValueKey('call-share-self'),
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitContain,)
                        // IgnorePointer is load-bearing: ColoredBox hit-tests
                        // opaque, and full-screen it would sit over the
                        // long-press layer and make the stats overlay
                        // untogglable on the one phone mid-share.
                        : const IgnorePointer(
                            key: ValueKey('call-share-panel'),
                            child: _SharingCard(big: true),
                          )
                    // The crop follows the frame, not the `screen` broadcast —
                    // see CallVideo for why the broadcast was the wrong input.
                    : CallVideo(
                        renderer: call.remoteScreen
                            ? call.screenRenderer
                            : call.remoteRenderer,
                        portraitHint: call.remoteScreen,
                      ),
              )
            else
              const Positioned.fill(
                key: ValueKey('call-remote-placeholder'),
                child: ColoredBox(color: MilesColors.night),
              ),

            // The numbers that tell a capture problem from an encoder problem
            // from a network problem — they look identical on screen otherwise.
            ValueListenableBuilder<bool>(
              key: const ValueKey('call-stats'),
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
                key: const ValueKey('call-no-relay'),
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
                key: const ValueKey('call-centrepiece'),
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

            // The faces. One tile while nobody is sharing (mine); two while
            // somebody is (theirs, then mine), because the big view is then
            // the shared display and neither person should have to give up
            // seeing the other to look at it.
            if (video && (calling || connected) && !anyShare)
              Align(
                key: const ValueKey('call-local'),
                alignment: connected ? Alignment.topRight : Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _FaceTile(
                    key: const ValueKey('call-face-local'),
                    big: !connected,
                    // Outside a share only — during one, every face is in the
                    // strip above the controls. The camera stays on the wire
                    // throughout, so this mirror shows what the partner
                    // actually receives.
                    child: RTCVideoView(call.localRenderer,
                        // Follows the actual camera. Pinned to true, the back
                        // camera showed the world reversed.
                        mirror: call.frontCamera,
                        // The preview is a thumbnail, so this is a big
                        // DOWNscale — 720p into ~120dp. medium adds
                        // mipmapping, which is what stops a downscale
                        // shimmering and looking cheap. Deliberately not
                        // applied to the remote view: that one UPscales,
                        // where mipmaps do nothing and would only soften it
                        // further.
                        filterQuality: FilterQuality.medium,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,),
                  ),
                ),
              ),

            // Minimize (keep call running, use the app).
            if (!ringing)
              SafeArea(
                key: const ValueKey('call-minimize'),
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

            // The bottom cluster: during a share, the face strip rides just
            // above the controls — one Column, so a two-run controls Wrap on
            // a narrow screen pushes the strip up instead of colliding.
            Align(
              key: const ValueKey('call-controls'),
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (anyShare) ...[
                    FaceStrip(
                      key: const ValueKey('call-face-strip'),
                      tiles: [
                        _FaceTile(
                          key: const ValueKey('call-face-remote'),
                          height: 150,
                          child: CallVideo(
                            renderer: call.remoteRenderer,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                        _FaceTile(
                          key: const ValueKey('call-face-local'),
                          height: 150,
                          child: RTCVideoView(call.localRenderer,
                              mirror: call.frontCamera,
                              filterQuality: FilterQuality.medium,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitCover,),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                  Padding(
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
                            // Live during a share too: the camera never leaves
                            // the call's connection — the display rides its
                            // own — so these always do what they say.
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
                            // Connected-only: the share opens its own peer
                            // connection, and there is no one to answer it
                            // until the call itself is up.
                            if (connected)
                              _RoundBtn(
                                  icon: call.sharingScreen
                                      ? Icons.stop_screen_share
                                      : Icons.screen_share,
                                  bg: call.sharingScreen
                                      ? MilesColors.ember
                                      : MilesColors.surface2,
                                  // Two whole-display captures at once is a
                                  // real feedback loop, not just a busy screen:
                                  // each display contains a live picture of the
                                  // other, so the image nests inside itself
                                  // until both encoders give up. The controller
                                  // refuses it; this says so before the tap.
                                  // Reads the ANNOUNCEMENT, not the pixels:
                                  // the button must lock the moment they say
                                  // they are sharing, not seconds later when
                                  // their first frame lands.
                                  disabled: call.remoteSharePending &&
                                      !call.sharingScreen,
                                  label: call.sharingScreen
                                      ? 'Stop'
                                      : call.remoteSharePending
                                          ? 'Sharing'
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
                ],
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
      required this.onTap,
      this.disabled = false,});
  final IconData icon;
  final Color bg;
  final String label;
  final VoidCallback onTap;

  /// Dimmed and inert. Kept in the layout rather than removed so the control
  /// row does not reflow under the user's thumb mid-call.
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: disabled ? null : onTap,
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
      ),
    );
  }
}

/// One face, at the size the call is currently using.
///
/// [big] is the pre-connect state, where the self-view is the centrepiece
/// rather than a corner tile. Everything else about the two sizes was already
/// duplicated inline; it is one widget now because there can be two of them.
class _FaceTile extends StatelessWidget {
  const _FaceTile({
    required this.child,
    this.big = false,
    this.height = 160,
    super.key,
  });

  final Widget child;
  final bool big;

  /// Mini-tile height — the strip runs slightly shorter tiles than the
  /// corner tile so the whole bottom cluster fits a small phone.
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        width: big ? 220 : 110,
        height: big ? 320 : height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: MilesColors.gilt.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

/// Stands in for the self-preview while this handset is sharing its display.
///
/// Not a live view of the capture — that would be a mirror inside the very
/// pixels being captured, which recurses. See the comment at its use site.
/// [big] scales it up for the whole-display share's big view, where an
/// app-scoped capture would have shown a live preview instead.
class _SharingCard extends StatelessWidget {
  const _SharingCard({this.big = false});

  final bool big;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MilesColors.surface2,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.screen_share,
              color: MilesColors.gilt, size: big ? 48 : 26,),
          SizedBox(height: big ? 16 : 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: big ? 32 : 8),
            child: Text(
              'Sharing your screen — they see exactly what this screen '
              'shows.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MilesColors.cream50.withValues(alpha: 0.85),
                fontSize: big ? 14 : 11,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
