import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
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
    } catch (_) {
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
      return const Center(
        child: Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 48),
      );
    }
    return Center(
      child: chewie == null
          ? const CircularProgressIndicator(color: Colors.white70)
          : Chewie(controller: chewie),
    );
  }
}
