import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:video_player/video_player.dart';

/// The Opening — the film a couple sees once, the first time they are together
/// in the app.
///
/// THE RULE THIS SCREEN EXISTS UNDER
/// `intro_splash_screen.dart` records why the app's previous intro video was
/// deleted: it "meant nobody could open the app without waiting out a clip they
/// had already seen." So this is not a gate and never blocks entry —
///  * [onDone] is called on EVERY exit path, including failure, so whoever
///    pushed this route always gets control back;
///  * the skip is on screen from the first frame, not after a polite delay;
///  * a decode failure pops instantly and silently rather than showing an error
///    where a film should be;
///  * with animations off it never plays at all.
///
/// The asset carries NO audio track. The score belongs to MilesSound's loop
/// channel, where the user's mute and the server-side sound kill still govern
/// it — a baked-in track would bypass both.
class OpeningScreen extends StatefulWidget {
  const OpeningScreen({required this.onDone, super.key});


  /// Called exactly once, however the film ends. The flag is true ONLY when it
  /// played to its end — a skip and a decode failure both report false, so a
  /// walked-out-of film is never recorded as watched.
  final ValueChanged<bool> onDone;

  static const asset = 'assets/opening/opening.mp4';

  @override
  State<OpeningScreen> createState() => _OpeningScreenState();
}

class _OpeningScreenState extends State<OpeningScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _c;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Full bleed: a film with a status bar over it is a video, not an opening.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    // A phone asked to stop animating is not asked to sit through a film.
    if (MilesMotion.off(context)) {
      _finish();
      return;
    }
    final c = VideoPlayerController.asset(OpeningScreen.asset);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_watchForEnd);
      await c.play();
      setState(() => _c = c);
    } catch (e) {
      // The film is the ornament; entering the app is the point. Named, then
      // stepped over.
      debugPrint('opening: ${OpeningScreen.asset} failed to play: $e');
      // _finish BEFORE the cleanup, and the cleanup never awaited. dispose()
      // on a controller that failed to initialise can throw too, and when it
      // did the throw escaped this catch, onDone never fired, and the user was
      // left sitting on a black screen by the very handler written to stop
      // that happening. Caught by opening_screen_test.
      _finish();
      unawaited(c.dispose().catchError((Object _) {}));
    }
  }

  void _watchForEnd() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.position >= c.value.duration && !c.value.isPlaying) {
      _finish(completed: true);
    }
  }

  /// Idempotent: the end-of-film listener and a skip tap can both arrive.
  void _finish({bool completed = false}) {
    if (_done) return;
    _done = true;
    widget.onDone(completed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    // Pause when they leave, resume when they come back. Whoever pushed this
    // route decides whether a film they walked out of ever returns; this only
    // stops it playing to an empty room.
    if (state == AppLifecycleState.resumed) {
      c.play();
    } else {
      c.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _c?.removeListener(_watchForEnd);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Black until the first frame is ready — a spinner over a film reads
          // as a stall, and the wait is a few hundred milliseconds off the
          // bundle.
          if (c != null && c.value.isInitialized)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: c.value.size.width,
                height: c.value.size.height,
                child: VideoPlayer(c),
              ),
            ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: Semantics(
                button: true,
                label: 'Skip',
                child: TextButton(
                  onPressed: _finish,
                  child: Text(
                    'Skip',
                    style: MilesType.inter(
                      fontSize: 13,
                      color: MilesColors.cream50.withValues(alpha: 0.85),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
