import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// An [RTCVideoView] whose crop follows the frame that actually arrived.
///
/// The fit used to be chosen from `remoteScreen` — a Supabase broadcast — and
/// that is wrong twice over. It lands BEFORE the first screen frame decodes, so
/// the view letterboxed against still-camera-shaped frames for the length of
/// the swap; and it is fire-and-forget, so one dropped signal left a portrait
/// display cropped to Cover for the rest of the call, shaving the edges off the
/// thing both people were looking at. The frame knows its own shape. Ask it.
///
/// Holding the last good fit matters as much as computing it. The size change
/// arrives asynchronously on an EventChannel (`didTextureChangeVideoSize`, see
/// FlutterRTCVideoRenderer.java), and [RTCVideoValue.aspectRatio] returns
/// exactly 1.0 whenever width or height is still 0 — which is indistinguishable
/// from a genuinely square frame. Re-fitting on that value is what snapped the
/// view square in the middle of a camera -> screen swap.
class CallVideo extends StatefulWidget {
  const CallVideo({
    required this.renderer,
    this.mirror = false,
    this.filterQuality = FilterQuality.low,
    this.portraitHint = false,
    super.key,
  });

  final RTCVideoRenderer renderer;
  final bool mirror;
  final FilterQuality filterQuality;

  /// What to assume until the first frame says otherwise — in practice the
  /// partner's `screen` broadcast. A hint, never an override.
  final bool portraitHint;

  @override
  State<CallVideo> createState() => _CallVideoState();
}

class _CallVideoState extends State<CallVideo> {
  RTCVideoViewObjectFit? _fit;

  @override
  void initState() {
    super.initState();
    widget.renderer.addListener(_onValue);
    _fit = _fitFor(widget.renderer.value);
  }

  @override
  void didUpdateWidget(CallVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.renderer, widget.renderer)) return;
    oldWidget.renderer.removeListener(_onValue);
    widget.renderer.addListener(_onValue);
    // A different renderer is a different source; the held fit does not carry.
    _fit = _fitFor(widget.renderer.value);
  }

  @override
  void dispose() {
    widget.renderer.removeListener(_onValue);
    super.dispose();
  }

  void _onValue() {
    final next = _fitFor(widget.renderer.value);
    if (next == null || next == _fit || !mounted) return;
    setState(() => _fit = next);
  }

  /// null means "no frame has arrived yet" — keep whatever is on screen.
  static RTCVideoViewObjectFit? _fitFor(RTCVideoValue v) {
    if (v.width == 0 || v.height == 0) return null;
    // A shared phone display is portrait-tall and full of small text; cropping
    // it to fill would shave the edges off. A camera is landscape and should
    // fill, because letterboxing a face wastes most of the screen.
    return v.aspectRatio < 1.0
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;
  }

  @override
  Widget build(BuildContext context) => RTCVideoView(
        widget.renderer,
        mirror: widget.mirror,
        filterQuality: widget.filterQuality,
        objectFit: _fit ??
            (widget.portraitHint
                ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
      );
}
