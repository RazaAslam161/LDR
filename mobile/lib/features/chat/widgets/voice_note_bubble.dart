import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/features/chat/voice_note_cache.dart';
import 'package:miles/features/chat/voice_peaks.dart';
import 'package:miles/features/chat/voice_prefs.dart';

/// The conversation's one audio player, plus the identity of what it holds.
///
/// One player for the whole chat is right: two voice notes must never play
/// over each other, and a player per bubble is a decoder per bubble. What was
/// missing was WHICH note it was on. Every bubble subscribed to the same
/// playerStateStream and read `state.playing` straight off it, so one note
/// playing turned every voice bubble in the conversation into a pause button —
/// and tapping any of them paused a note somewhere else on screen.
class VoiceNotePlayer extends ChangeNotifier {
  VoiceNotePlayer() {
    _sub = _player.playerStateStream.listen((s) {
      // cancel() is asynchronous, so an event already in flight when the chat
      // closes would reach a disposed ChangeNotifier and throw.
      if (_disposed) return;
      // The ambient bed yields to a human voice: hold while a note actually
      // plays, release on every edge out of playing (pause, completion, a
      // swap to another note passes through here too). The edges pair by
      // construction — one hold per true transition, one release per false.
      final audible = s.playing && s.processingState == ProcessingState.ready;
      if (audible != _holdingAmbient) {
        _holdingAmbient = audible;
        unawaited(audible
            ? MilesSound.holdAmbient()
            : MilesSound.releaseAmbient(),);
      }
      // A note that has arrived is a note that can be moved. Any seek asked for
      // while it was still loading was DISCARDED by just_audio without a word —
      // it returns early on ProcessingState.loading — so it is replayed here
      // rather than lost. That drop is why a scrubber "works sometimes": warm
      // note seeks, cold note ignores you.
      if (s.processingState == ProcessingState.ready) _flushPendingSeek();
      // Reaching the end is not a pause: the note is no longer the current
      // one, so its bubble goes back to a play icon at the moment the audio
      // stops rather than sitting on a pause icon over silence.
      if (s.processingState == ProcessingState.completed) {
        final finished = _currentId;
        _currentId = null;
        if (finished != null) {
          // Zeroed rather than left at the end: resuming a note from its final
          // moment plays silence, which reads as a broken recording.
          unawaited(
            VoicePrefs.instance.remember(
              finished,
              position: Duration.zero,
              played: true,
            ),
          );
        }
      }
      notifyListeners();
    });
    // The duration arrives only once the audio has loaded, and it is the ONLY
    // total a note has when voice_duration_ms is null — which is permanent for
    // everything sent before that column existed.
    _durationSub = _player.durationStream.listen((_) {
      if (_disposed) return;
      notifyListeners();
    });
    // A voice note is CONTENT, and content plays on the media stream — the one
    // the volume rocker moves while it is playing.
    //
    // It did not. This app configures exactly ONE AudioSession, and
    // JustAudioEngine sets it to sonification so a 200ms cue ducks the user's
    // music instead of killing it (just_audio_engine.dart:50). just_audio then
    // pushes THAT session's attributes onto every player it builds
    // (just_audio.dart:359 and :1686), and USAGE_ASSISTANCE_SONIFICATION maps
    // to STREAM_SYSTEM in AudioAttributes.toVolumeStreamType — a stream the
    // media rocker does not touch. So a note played at whatever the system
    // stream was set to and ignored the listener pressing volume down.
    //
    // The pair is the fix: attributes of our own, and
    // androidApplyAudioAttributes:false so the cue session cannot overwrite
    // them the next time it is configured.
    unawaited(_player.setAndroidAudioAttributes(const AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      usage: AndroidAudioUsage.media,
    ),),);
  }

  final AudioPlayer _player = AudioPlayer(androidApplyAudioAttributes: false);
  StreamSubscription<PlayerState>? _sub;
  StreamSubscription<Duration?>? _durationSub;
  bool _disposed = false;
  bool _holdingAmbient = false;

  /// The message whose note is loaded, or null when nothing is.
  String? _currentId;

  /// Bumped on every load. Two taps on two different notes both suspend on the
  /// `await setUrl` below; without this the slower one wins on arrival and
  /// plays the note the user asked for first, over the one they asked for
  /// second.
  int _loadToken = 0;

  /// A seek that arrived while the source was still loading.
  Duration? _pendingSeek;

  /// Which note has a finger on its waveform, or null.
  ///
  /// The chat's list reads this to take that row's swipe-to-reply out of
  /// service for the duration. Every row is wrapped in a Dismissible carrying
  /// its own horizontal drag recogniser, and leaving both live hands the
  /// decision to the gesture arena, which resolves on pointer-event ordering:
  /// the way you want for a slow careful scrub, and the way you do not for a
  /// flick, where both recognisers cross the slop in the same event. A
  /// Dismissible with `direction: none` installs no recogniser at all, so there
  /// is nothing left to arbitrate.
  final ValueNotifier<String?> scrubbing = ValueNotifier<String?>(null);

  /// Whether THIS message is the one being heard right now.
  bool isPlaying(String messageId) =>
      _currentId == messageId && _player.playing;

  /// Whether THIS message is the one the player holds — playing or paused.
  ///
  /// The speed chip hangs off this rather than off [isPlaying]. Speed is one
  /// setting for the conversation, not a property of a message, and drawing it
  /// on all three hundred bubbles made a shared control look like a private
  /// one: tapping 1.5x on one note visibly changed the number on every other
  /// note, which reads as a bug however it was meant. On the note actually
  /// loaded, the same tap reads as what it is.
  bool isCurrent(String messageId) => _currentId == messageId;

  /// The rate every note plays at, remembered across notes and across launches.
  double get speed => VoicePrefs.instance.speed;

  /// Whether this note has been listened to on this handset.
  bool wasPlayed(String messageId) => VoicePrefs.instance.wasPlayed(messageId);

  /// How long the loaded note runs, once the audio itself says so. Null for
  /// every note that is not the current one.
  Duration? totalOf(String messageId) =>
      _currentId == messageId ? _player.duration : null;

  /// Where the current note has got to, for the counter on its bubble.
  ///
  /// Deliberately NOT folded into notifyListeners(): this ticks several times a
  /// second, and every voice bubble on screen listens to this object, so
  /// notifying on it would rebuild all of them at that rate. Only the bubble
  /// that is actually playing subscribes, and only its label rebuilds.
  Stream<Duration> get positionStream => _player.positionStream;

  /// Step to the next speed and apply it to whatever is loaded now.
  Future<void> cycleSpeed() => setSpeed(VoicePrefs.instance.nextSpeed());

  Future<void> setSpeed(double value) async {
    await VoicePrefs.instance.setSpeed(value);
    if (_disposed) return;
    notifyListeners();
    await _player.setSpeed(value);
  }

  /// Play [messageId] from [url], or pause it if it is already the one
  /// playing. Starting a different note replaces the current one.
  Future<void> toggle(String messageId, String url) async {
    if (_currentId == messageId) {
      if (_player.playing) {
        await _player.pause();
        if (_disposed) return;
        await _remember(messageId);
      } else {
        // A note played to the end leaves the position at the end, so plain
        // play() would return instantly having played nothing.
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
      return;
    }
    await _load(messageId, url, resume: true);
    if (_disposed || _currentId != messageId) return;
    await _player.play();
  }

  /// Move [messageId] to [position], loading it first when it is not the note
  /// already in the player — so dragging the waveform of a note that is not
  /// playing starts it from where the finger landed.
  Future<void> seek(String messageId, String url, Duration position) async {
    if (_currentId != messageId) {
      await _load(messageId, url, resume: false);
      if (_disposed || _currentId != messageId) return;
      await _seekNow(position);
      if (_disposed || _currentId != messageId) return;
      await _player.play();
      return;
    }
    await _seekNow(position);
    if (_disposed || _currentId != messageId) return;
    await _remember(messageId);
  }

  Future<void> _load(
    String messageId,
    String url, {
    required bool resume,
  }) async {
    final token = ++_loadToken;
    _currentId = messageId;
    _pendingSeek = null;
    notifyListeners();
    try {
      // From disk when it can be, from the network when it cannot. A note that
      // is already on the handset seeks instantly, which is the difference
      // between the waveform being a control and being a picture.
      final local = await VoiceNoteCache.fileFor(url);
      if (_disposed || token != _loadToken) return;
      if (local != null) {
        await _player.setFilePath(local);
      } else {
        await _player.setUrl(url);
      }
      // AFTER the load, not before. just_audio re-applies the rate when it
      // re-activates a platform, but a plain source swap on an already-active
      // platform is not that path, and whether the rate survives it is then the
      // platform's business rather than ours.
      if (_disposed || token != _loadToken) return;
      await _player.setSpeed(VoicePrefs.instance.speed);
      if (_disposed || token != _loadToken) return;
      if (resume) {
        final from = VoicePrefs.instance.positionOf(messageId);
        // Under a second in is not a resume, it is the start; jumping there
        // would look like the note refusing to play from the beginning.
        if (from > const Duration(seconds: 1)) await _seekNow(from);
      }
      if (_disposed || token != _loadToken) return;
      await VoicePrefs.instance.remember(messageId, played: true);
      if (_disposed || token != _loadToken) return;
      notifyListeners();
    } catch (_) {
      if (_disposed || token != _loadToken) return;
      _currentId = null;
      notifyListeners();
      rethrow;
    }
  }

  /// Seek, or park the request until the source is ready.
  Future<void> _seekNow(Duration position) async {
    final state = _player.processingState;
    if (state == ProcessingState.idle || state == ProcessingState.loading) {
      _pendingSeek = position;
      return;
    }
    await _player.seek(position);
  }

  void _flushPendingSeek() {
    final pending = _pendingSeek;
    if (pending == null) return;
    _pendingSeek = null;
    unawaited(_player.seek(pending));
  }

  Future<void> _remember(String messageId) => VoicePrefs.instance
      .remember(messageId, position: _player.position, played: true);

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    unawaited(_durationSub?.cancel());
    scrubbing.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }
}

/// The note's own loudness, drawn as bars and filled as it plays.
///
/// Scaled against the loudest bar in THIS note rather than against full scale.
/// The stored bytes are absolute — the column documents 255 as full scale — and
/// a note recorded at arm's length is honestly quiet, but drawing it honestly
/// quiet makes every distant note a flat line. Absolute in the row, relative on
/// the screen.
class VoiceWavePainter extends CustomPainter {
  const VoiceWavePainter({
    required this.peaks,
    required this.progress,
    required this.playedColor,
    required this.restColor,
  });

  final Uint8List peaks;

  /// 0..1 of the note that has been heard.
  final double progress;
  final Color playedColor;
  final Color restColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final loudest = peaks.reduce((a, b) => a > b ? a : b);
    // Guarded even though the encoder refuses an all-zero row: this also draws
    // rows written by other builds of the app, which this one does not control.
    if (loudest == 0) return;

    final slot = size.width / peaks.length;
    // A bar narrower than a physical pixel disappears; the gap is what is left.
    final barWidth = (slot * 0.55).clamp(1.0, 3.0);
    final radius = Radius.circular(barWidth / 2);
    final playedTo = size.width * progress.clamp(0.0, 1.0);
    final paint = Paint();

    for (var i = 0; i < peaks.length; i++) {
      final centre = slot * i + slot / 2;
      // Never zero: a silent moment inside a note is still part of the note,
      // and a gap in the row reads as a rendering fault.
      final height =
          (peaks[i] / loudest * size.height).clamp(2.0, size.height);
      paint.color = centre <= playedTo ? playedColor : restColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(centre, size.height / 2),
            width: barWidth,
            height: height,
          ),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(VoiceWavePainter old) =>
      old.progress != progress ||
      old.peaks != peaks ||
      old.playedColor != playedColor ||
      old.restColor != restColor;
}

/// A voice note in the conversation: play/pause, its real waveform, the speed
/// it plays at, and save.
///
/// Deliberately dumb about the player — [playing] is decided by
/// [VoiceNotePlayer] against this message's id, so the icon can only ever be
/// about this bubble. It is stateful only about a drag in progress, which
/// belongs to the finger and to nothing else.
class VoiceNoteBubble extends StatefulWidget {
  const VoiceNoteBubble({
    required this.url,
    required this.playing,
    required this.onToggle,
    required this.senderName,
    required this.bubble,
    this.durationMs,
    this.positionStream,
    this.peaks,
    this.messageId,
    this.speed = 1.0,
    this.onCycleSpeed,
    this.onSeek,
    this.onScrub,
    this.playerTotal,
    this.unplayed = false,
    this.current = false,
    super.key,
  });

  final String url;
  final bool playing;
  final VoidCallback onToggle;
  final String senderName;

  /// The fill of the bubble this sits inside — the controls resolve their
  /// tint against it rather than washing over it.
  final Color bubble;

  /// How long the note runs, in milliseconds, or null when nobody knows.
  ///
  /// Null is permanent for two populations rather than transitional: every note
  /// sent before messages.voice_duration_ms existed, and everything from a
  /// client older than the column — the fleet is sideloaded and has no update
  /// channel, so those keep arriving indefinitely. Those bubbles are drawn with
  /// no label at all. Not "0:00", which would be a lie about a note that really
  /// runs seven seconds, and not a "--:--" placeholder, which is a technical
  /// artefact to leave sitting on a conversation forever.
  final int? durationMs;

  /// Position ticks from the conversation's one player, read only while
  /// [playing] is true — so exactly one bubble is ever subscribed, and an idle
  /// list rebuilds nothing.
  final Stream<Duration>? positionStream;

  /// The recording's own shape, decoded. Null draws a pattern from
  /// [messageId] instead — see [VoicePeaks.patternFor].
  final Uint8List? peaks;

  /// Only needed for the fallback pattern, so a note with no stored shape at
  /// least looks like itself and not like every other note.
  final String? messageId;

  final double speed;
  final VoidCallback? onCycleSpeed;

  /// Seek this note to [Duration]. Null leaves the waveform inert, which is
  /// what a note whose total nobody knows yet has to be.
  final void Function(Duration)? onSeek;

  /// True while a finger is down on the waveform. The chat uses it to stand
  /// the row's swipe-to-reply down so the two gestures cannot compete.
  final void Function({required bool active})? onScrub;

  /// The total the audio itself reports, which is the only one a note with no
  /// stored duration has.
  final Duration? playerTotal;

  /// Never listened to. Drawn as a dot, and only ever on the partner's notes.
  final bool unplayed;

  /// This is the note the conversation's player currently holds.
  ///
  /// Gates the speed chip, and only the speed chip. The rate is one setting
  /// shared by every note — showing it on all of them turned a playback control
  /// into what looked like a per-message one.
  final bool current;

  @override
  State<VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

/// The waveform's own box. Named so a widget test can put a finger exactly
/// on it — the gesture this feature turns on is the one thing here that no
/// amount of reading the source can confirm.
const waveKey = ValueKey<String>('voice-wave');

class _VoiceNoteBubbleState extends State<VoiceNoteBubble> {
  /// How wide the waveform draws. Fixed rather than expanded, because the
  /// bubble sizes itself to its content and an unbounded row would stretch a
  /// two-second note across the whole screen.
  static const double _waveWidth = 132;
  static const double _waveHeight = 26;

  double? _dragFraction;
  int _lastHapticBar = -1;

  /// The total to measure a drag against: the audio's own answer first, the
  /// stored column second.
  Duration? get _seekTotal {
    final fromPlayer = widget.playerTotal;
    if (fromPlayer != null && fromPlayer > Duration.zero) return fromPlayer;
    final ms = widget.durationMs;
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms);
  }

  /// The label, in whole seconds, or null when there is nothing honest to say.
  ///
  /// Rounded rather than truncated, and floored at one second: a note that was
  /// held for a moment is "0:01", because a note that exists cannot be nothing
  /// long — and 0:00 beside a play button reads as a broken recording.
  Duration? get _total {
    final ms = widget.durationMs;
    if (ms == null || ms <= 0) return null;
    return Duration(seconds: (ms / 1000).round().clamp(1, 86400));
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Elapsed while it plays, total when it does not, nothing when unknown.
  Widget? _time() {
    const style = TextStyle(
      color: MilesColors.taupe,
      fontSize: 11,
      // Fixed-width digits: without them the glyphs change width as the
      // counter runs and the save button beside it shuffles left and right.
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final dragging = _dragFraction;
    final total = _seekTotal;
    if (dragging != null && total != null) {
      return Text(_clock(total * dragging), style: style);
    }
    final ticks = widget.positionStream;
    if (widget.playing && ticks != null) {
      return StreamBuilder<Duration>(
        stream: ticks,
        builder: (_, snap) =>
            Text(_clock(snap.data ?? Duration.zero), style: style),
      );
    }
    final stored = _total;
    return stored == null ? null : Text(_clock(stored), style: style);
  }

  void _setScrub(double? fraction) {
    setState(() => _dragFraction = fraction);
    widget.onScrub?.call(active: fraction != null);
  }

  void _onPointer(Offset local) {
    final total = _seekTotal;
    if (total == null || widget.onSeek == null) return;
    final fraction = (local.dx / _waveWidth).clamp(0.0, 1.0);
    final bars = widget.peaks?.length ?? VoicePeaks.bars;
    final bar = (fraction * bars).floor();
    if (bar != _lastHapticBar) {
      _lastHapticBar = bar;
      unawaited(HapticFeedback.selectionClick());
    }
    _setScrub(fraction);
  }

  void _endScrub() {
    final fraction = _dragFraction;
    final total = _seekTotal;
    _lastHapticBar = -1;
    _setScrub(null);
    if (fraction == null || total == null) return;
    widget.onSeek?.call(total * fraction);
  }

  Widget _wave() {
    final shape = widget.peaks ?? VoicePeaks.patternFor(widget.messageId ?? '');
    final seekable = _seekTotal != null && widget.onSeek != null;
    return Listener(
      // Listener, not a drag recogniser. It never enters the gesture arena, so
      // it cannot lose the row's swipe-to-reply — and while a finger is down
      // the chat stands that Dismissible down anyway (see
      // VoiceNotePlayer.scrubbing), which is what makes this deterministic
      // instead of a bet on pointer-event ordering.
      onPointerDown: seekable ? (e) => _onPointer(e.localPosition) : null,
      onPointerMove: seekable ? (e) => _onPointer(e.localPosition) : null,
      onPointerUp: seekable ? (_) => _endScrub() : null,
      onPointerCancel: seekable ? (_) => _endScrub() : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        key: waveKey,
        width: _waveWidth,
        height: _waveHeight,
        child: _progressPaint(shape),
      ),
    );
  }

  Widget _progressPaint(Uint8List shape) {
    const played = MilesColors.cream50;
    final rest = MilesColors.cream50.withValues(alpha: 0.35);
    final dragging = _dragFraction;
    if (dragging != null) {
      return CustomPaint(
        painter: VoiceWavePainter(
          peaks: shape,
          progress: dragging,
          playedColor: played,
          restColor: rest,
        ),
      );
    }
    final ticks = widget.positionStream;
    final total = _seekTotal;
    if (widget.playing && ticks != null && total != null) {
      return StreamBuilder<Duration>(
        stream: ticks,
        builder: (_, snap) => CustomPaint(
          painter: VoiceWavePainter(
            peaks: shape,
            progress: total.inMilliseconds == 0
                ? 0
                : (snap.data ?? Duration.zero).inMilliseconds /
                    total.inMilliseconds,
            playedColor: played,
            restColor: rest,
          ),
        ),
      );
    }
    return CustomPaint(
      painter: VoiceWavePainter(
        peaks: shape,
        progress: 0,
        playedColor: played,
        restColor: rest,
      ),
    );
  }

  /// The rate, shown rather than counted.
  ///
  /// A chip that displays "1.5x" needs no memory of how many times it has been
  /// tapped; a chip that only cycles does. Tinted once it leaves 1x so a note
  /// left fast is visibly not normal.
  Widget _speedChip() {
    final fast = widget.speed != 1.0;
    // No ':' anywhere in this label, deliberately: an unlabelled note asserts
    // it renders no clock, and 'x' is also the one glyph here that cannot come
    // back as mojibake the way a multiplication sign can.
    final text = widget.speed == widget.speed.roundToDouble()
        ? '${widget.speed.toInt()}x'
        : '${widget.speed}x';
    return GestureDetector(
      onTap: widget.onCycleSpeed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: MilesColors.tint(
            fast ? MilesColors.ember : MilesColors.cream50,
            fast ? 0.28 : 0.12,
            over: widget.bubble,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: fast ? MilesColors.ember : MilesColors.taupe,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final time = _time();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: widget.onToggle,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: MilesColors.tint(
                      MilesColors.cream50,
                      0.15,
                      over: widget.bubble,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: MilesColors.cream50,
                    size: 22,
                  ),
                ),
                if (widget.unplayed)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: MilesColors.ember,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _wave(),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Both the gap and the label go together, so an unlabelled note
                // keeps exactly the spacing it has today rather than gaining a
                // hole where the time would have been.
                if (time != null) ...[time, const SizedBox(width: 8)],
                // Only on the loaded note. The chip changes a setting the whole
                // conversation shares, so putting one on every bubble meant a
                // single tap silently rewrote the number on all of them.
                if (widget.current) _speedChip(),
              ],
            ),
          ],
        ),
        const SizedBox(width: 8),
        SaveMediaButton(
          size: 16,
          color: MilesColors.taupe,
          onSave: () => SaveMediaService.saveVoiceToVault(
            url: widget.url,
            senderName: widget.senderName,
          ),
        ),
      ],
    );
  }
}
