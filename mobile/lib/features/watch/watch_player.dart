/// One surface the sync protocol can drive, whatever is actually playing.
///
/// The screen used to hold a [YoutubePlayerController] directly, so "watch
/// together" meant "watch YouTube together" and a plain .mp4 link — the most
/// ordinary video there is — had nowhere to go but the browser, where nothing
/// stays in sync.
///
/// The protocol in watch_protocol.dart never cared which player it was talking
/// to: it needs a position, a playing flag, and three commands. That is exactly
/// this interface, so both backends sync with no protocol change at all.
library;

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/features/watch/watch_source.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

/// Why playback is impossible, when it is.
typedef WatchFault = String;

abstract class WatchPlayer implements Listenable {
  /// The source key this player is showing, as carried on the wire.
  String get key;

  /// False until commands will actually be honoured. Both backends silently
  /// drop everything before this — that is the bug that lost the partner's
  /// video without a trace — so callers must queue rather than fire and hope.
  bool get isReady;

  bool get isPlaying;
  Duration get position;

  /// Non-null once playback has definitively failed. A spinner is never the
  /// resting state.
  WatchFault? get fault;

  void play();
  void pause();
  void seekTo(Duration position);

  /// Media loudness, 0..1.
  ///
  /// Exists so a live call can duck the film. Without it there was no way to
  /// lower one without lowering the other, and call audio and video audio both
  /// played at full volume — which on a shared film means neither of them can
  /// hear the other speak.
  void setVolume(double volume);

  Widget view(BuildContext context);
  void dispose();
}

/// Direct media: .mp4, .m3u8, .mpd and friends, played in-process.
///
/// [VideoPlayerController] already is this interface — position, isPlaying and
/// the three commands are all native to it — so this is mostly the ready and
/// fault plumbing the abstraction promises, plus Chewie for the controls.
class MediaWatchPlayer extends ChangeNotifier implements WatchPlayer {
  MediaWatchPlayer(this.source) {
    _open();
  }

  final WatchSource source;

  VideoPlayerController? _vp;
  ChewieController? _chewie;
  WatchFault? _fault;
  bool _ready = false;

  @override
  String get key => source.key;

  @override
  bool get isReady => _ready;

  @override
  WatchFault? get fault => _fault;

  @override
  bool get isPlaying => _vp?.value.isPlaying ?? false;

  @override
  Duration get position => _vp?.value.position ?? Duration.zero;

  Future<void> _open() async {
    try {
      final vp = VideoPlayerController.networkUrl(
        Uri.parse(source.key),
        // Told explicitly rather than sniffed: a manifest served without a
        // helpful content-type is otherwise treated as a progressive file and
        // fails with nothing useful to show the user.
        formatHint: switch (source.format) {
          MediaFormat.hls => VideoFormat.hls,
          MediaFormat.dash => VideoFormat.dash,
          MediaFormat.ss => VideoFormat.ss,
          _ => VideoFormat.other,
        },
      );
      _vp = vp;
      // Forwarded before initialize so a failure during it is still surfaced.
      vp.addListener(_onValue);
      await vp.initialize();
      if (source.startAt > Duration.zero) await vp.seekTo(source.startAt);
      _chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: false,
        showControlsOnInitialize: false,
        allowFullScreen: true,
        deviceOrientationsAfterFullScreen: const [DeviceOrientation.portraitUp],
        materialProgressColors: ChewieProgressColors(
          playedColor: const Color(0xFFE0785A),
          handleColor: const Color(0xFFE0785A),
        ),
      );
      _ready = true;
      notifyListeners();
    } catch (e) {
      _fault = 'This video would not open. The link may have expired, or the '
          'file may be in a format this phone cannot play.';
      notifyListeners();
    }
  }

  void _onValue() {
    final err = _vp?.value.errorDescription;
    if (err != null && _fault == null) {
      _fault = 'Playback stopped: $err';
    }
    notifyListeners();
  }

  @override
  void play() => _vp?.play();

  @override
  void pause() => _vp?.pause();

  @override
  void seekTo(Duration position) => _vp?.seekTo(position);

  @override
  void setVolume(double volume) => _vp?.setVolume(volume.clamp(0, 1));

  @override
  Widget view(BuildContext context) {
    final chewie = _chewie;
    if (chewie == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: _vp!.value.aspectRatio,
      child: Chewie(controller: chewie),
    );
  }

  @override
  void dispose() {
    _vp?.removeListener(_onValue);
    // Chewie first: it holds the VideoPlayerController and touches it while
    // tearing its own controls down. Same order as VideoSurface, same reason.
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }
}

/// YouTube, through the iframe player.
class YoutubeWatchPlayer extends ChangeNotifier implements WatchPlayer {
  YoutubeWatchPlayer(this.source) {
    controller = YoutubePlayerController(
      initialVideoId: source.key,
      // autoPlay off is what makes a stuck spinner impossible: the package
      // hides its play button behind `!flags.autoPlay || playing || paused`,
      // so with autoPlay on there is nothing to tap when a video never starts.
      // onReady starts playback anyway, so nothing is lost.
      //
      // hideThumbnail closes an Image.network to i3.ytimg.com from the app's
      // own HTTP stack, outside the webview — an unencrypted disclosure of
      // what the couple is watching.
      flags: YoutubePlayerFlags(
        autoPlay: false,
        hideThumbnail: true,
        startAt: source.startAt.inSeconds,
      ),
    )..addListener(notifyListeners);
  }

  final WatchSource source;
  late final YoutubePlayerController controller;
  WatchFault? _fault;

  @override
  String get key => source.key;

  @override
  bool get isReady => controller.value.isReady;

  @override
  WatchFault? get fault => _fault;

  set fault(WatchFault? f) {
    _fault = f;
    notifyListeners();
  }

  @override
  bool get isPlaying => controller.value.isPlaying;

  @override
  Duration get position => controller.value.position;

  @override
  void play() => controller.play();

  @override
  void pause() => controller.pause();

  @override
  void setVolume(double volume) =>
      // youtube_player_flutter takes 0..100.
      controller.setVolume((volume.clamp(0, 1) * 100).round());

  @override
  void seekTo(Duration position) => controller.seekTo(position);

  /// Only meaningful for YouTube: the media backend is rebuilt per source.
  void load(String videoId, Duration startAt) =>
      controller.load(videoId, startAt: startAt.inSeconds);

  @override
  Widget view(BuildContext context) => YoutubePlayer(
        controller: controller,
        showVideoProgressIndicator: true,
        progressIndicatorColor: const Color(0xFFE0785A),
      );

  @override
  void dispose() {
    controller
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}
