import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:video_player/video_player.dart';

/// A playing video, and nothing around it.
///
/// A widget rather than a route, because in the pager a video is one page of
/// several and cannot push anything. Mounting it starts a platform decoder and
/// a network session; unmounting it ends both. That is the whole contract, and
/// it is what lets the pager keep exactly one decoder alive across a run of
/// videos instead of one per built page.
class VideoSurface extends StatefulWidget {
  const VideoSurface({required this.url, super.key});

  final String url;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface>
    with WidgetsBindingObserver {
  VideoPlayerController? _vp;

  /// Why initialize() failed, so the UI can say something true rather than
  /// showing the same blank tile for every cause.
  Object? _error;
  ChewieController? _chewie;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final vp = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await vp.initialize();
    } catch (e) {
      // Logged, not swallowed. This catch used to be `catch (_)`, which threw
      // away the only evidence of why a video would not play — and the sender
      // never sees the failure, because their own bubble renders from a file
      // that is still on their disk. So the one person who could report it had
      // nothing to report but "it does not work".
      //
      // The three causes are genuinely different and need different answers: a
      // codec the DEVICE cannot decode (screen recordings are frequently HEVC,
      // and a phone that recorded one can always play it while an older
      // handset cannot), an object the signed URL cannot reach, and a network
      // that died mid-initialize. Only the first is permanent.
      _error = e;
      Diag.record(DiagArea.media, 'video_init_failed', fields: {
        'error': e.runtimeType.toString(),
        'detail': e.toString(),
      });
      await vp.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) {
      await vp.dispose();
      return;
    }
    setState(() {
      _vp = vp;
      _chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: true,
        aspectRatio: vp.value.aspectRatio == 0 ? 16 / 9 : vp.value.aspectRatio,
      );
    });
  }

  /// Sound coming out of a phone that is face-down, or in another app, is the
  /// bug this exists for. Backgrounding is not a page change and nothing else
  /// would have caught it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _vp?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Chewie first: it holds the VideoPlayerController and will touch it while
    // tearing its own controls down.
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chewie = _chewie;
    if (_failed) {
      // An icon alone said "broken" and nothing else — no cause, and no way
      // forward. A video this phone cannot decode is not the same problem as
      // one it cannot reach, and the person looking at it can act on the
      // difference: the first is permanent on this handset and worth opening
      // elsewhere, the second is worth trying again.
      final unsupported = _error.toString().toLowerCase().contains('source') ||
          _error.toString().toLowerCase().contains('format') ||
          _error.toString().toLowerCase().contains('decoder');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white54, size: 44,),
              const SizedBox(height: 12),
              Text(
                unsupported
                    ? "This phone can't play this video's format."
                    : "This video couldn't be loaded.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                unsupported
                    ? 'Save it and open it in another player.'
                    : 'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: chewie == null
          ? const CircularProgressIndicator(color: Colors.white70)
          : Chewie(controller: chewie),
    );
  }
}
