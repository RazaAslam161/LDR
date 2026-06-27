import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:video_player/video_player.dart';

/// Full-screen intro video played as the cinematic "unlock" moment — after a
/// successful authentication through the News cover, before the real app shows.
///
/// Behaviour:
/// - Plays the bundled intro.mp4 from assets (no loop, volume 0.6).
/// - Tap anywhere advances immediately.
/// - Auto-advances when the video reaches its end.
/// - On advance it calls [onComplete] — the caller decides what happens next
///   (it does NOT navigate the router itself).
class IntroVideoScreen extends StatefulWidget {
  const IntroVideoScreen({super.key, required this.onComplete});

  /// Fired exactly once when the video ends or the user taps to advance.
  final VoidCallback onComplete;

  @override
  State<IntroVideoScreen> createState() => _IntroVideoScreenState();
}

class _IntroVideoScreenState extends State<IntroVideoScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _controller = VideoPlayerController.asset('assets/videos/intro.mp4');
    await _controller!.initialize();
    _controller!.setLooping(false);
    _controller!.setVolume(0.6);
    _controller!.addListener(_onProgress);
    if (!mounted) return;
    setState(() => _initialized = true);
    await _controller!.play();
  }

  void _onProgress() {
    if (_controller == null || _done) return;
    final pos = _controller!.value.position;
    final dur = _controller!.value.duration;
    if (dur.inMilliseconds > 0 && pos >= dur) {
      _advance();
    }
  }

  void _advance() {
    if (_done) return;
    _done = true;
    _controller?.removeListener(_onProgress);
    _controller?.pause();
    if (!mounted) return;
    // The caller decides what happens after the reveal (pop + show real app).
    widget.onComplete();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onProgress);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.navy950,
      body: GestureDetector(
        onTap: _advance,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video fills the screen.
            if (_initialized && _controller != null)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                ),
              )
            else
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),

            // Brand overlay — bottom, so it never covers the couple in frame.
            Positioned(
              bottom: 80,
              left: 24,
              right: 24,
              child: GlassPanel(
                blur: 20,
                radius: 24,
                padding:
                    const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Tethered',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.fraunces(
                        fontSize: 36,
                        fontStyle: FontStyle.italic,
                        color: MilesColors.cream50,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'your love, closer than distance',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: MilesColors.taupe,
                      ),
                    ),
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
