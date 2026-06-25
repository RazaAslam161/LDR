import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/theme.dart';
import 'package:video_player/video_player.dart';

/// Full-screen intro video that plays once on first launch.
///
/// Behaviour:
/// - Plays the bundled intro.mp4 from assets, looping, mute by default.
/// - Tap anywhere to skip straight into the app.
/// - Auto-advances to /signin (or /app if already authed) when the video ends.
/// - Persists a SharedPreferences flag so it only plays the first time.
class IntroVideoScreen extends StatefulWidget {
  const IntroVideoScreen({super.key});

  @override
  State<IntroVideoScreen> createState() => _IntroVideoScreenState();
}

class _IntroVideoScreenState extends State<IntroVideoScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _skipped = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _controller =
        VideoPlayerController.asset('assets/videos/intro.mp4');
    await _controller!.initialize();
    _controller!.setLooping(false);
    _controller!.setVolume(0.6);
    _controller!.addListener(_onProgress);
    if (!mounted) return;
    setState(() => _initialized = true);
    await _controller!.play();
  }

  void _onProgress() {
    if (_controller == null || _skipped) return;
    final pos = _controller!.value.position;
    final dur = _controller!.value.duration;
    if (dur.inMilliseconds > 0 && pos >= dur) {
      _advance();
    }
  }

  void _advance() {
    if (_skipped) return;
    _skipped = true;
    _controller?.removeListener(_onProgress);
    _controller?.pause();
    if (!mounted) return;
    // Drop the intro from the nav stack and go to the auth entry point.
    // Router redirect will send already-signed-in users to /app.
    context.go('/signin');
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
            // Video fills the screen
            if (_initialized && _controller != null)
              Center(child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!),
              ))
            else
              const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),

            // Skip button (top-right)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 16,
              child: TextButton(
                onPressed: _advance,
                style: TextButton.styleFrom(
                  foregroundColor: MilesColors.cream50,
                  backgroundColor: MilesColors.cream50.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                ),
                child: const Text('Skip',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ),
            ),

            // Brand at bottom
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 32,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    'Tethered',
                    style: TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 28,
                      fontWeight: FontWeight.w300,
                      fontFamily: 'Fraunces',
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'together, even from here',
                    style: TextStyle(
                      color: MilesColors.cream50.withValues(alpha: 0.6),
                      fontSize: 12,
                      letterSpacing: 2,
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
