import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/save_media_button.dart';

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
      // Reaching the end is not a pause: the note is no longer the current
      // one, so its bubble goes back to a play icon at the moment the audio
      // stops rather than sitting on a pause icon over silence.
      if (s.processingState == ProcessingState.completed) _currentId = null;
      notifyListeners();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _sub;
  bool _disposed = false;

  /// The message whose note is loaded, or null when nothing is.
  String? _currentId;

  /// Whether THIS message is the one being heard right now.
  bool isPlaying(String messageId) =>
      _currentId == messageId && _player.playing;

  /// Where the current note has got to, for the counter on its bubble.
  ///
  /// Deliberately NOT folded into notifyListeners(): this ticks several times a
  /// second, and every voice bubble on screen listens to this object, so
  /// notifying on it would rebuild all of them at that rate. Only the bubble
  /// that is actually playing subscribes, and only its label rebuilds.
  Stream<Duration> get positionStream => _player.positionStream;

  /// Play [messageId] from [url], or pause it if it is already the one
  /// playing. Starting a different note replaces the current one.
  Future<void> toggle(String messageId, String url) async {
    if (_currentId == messageId) {
      if (_player.playing) {
        await _player.pause();
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
    _currentId = messageId;
    notifyListeners();
    try {
      await _player.setUrl(url);
      await _player.play();
    } catch (_) {
      _currentId = null;
      notifyListeners();
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }
}

/// A voice note in the conversation: play/pause, a waveform, and save.
///
/// Deliberately dumb — [playing] is decided by [VoiceNotePlayer] against this
/// message's id, so the icon can only ever be about this bubble.
class VoiceNoteBubble extends StatelessWidget {
  const VoiceNoteBubble({
    required this.url,
    required this.playing,
    required this.onToggle,
    required this.senderName,
    required this.bubble,
    this.durationMs,
    this.positionStream,
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

  /// The label, in whole seconds, or null when there is nothing honest to say.
  ///
  /// Rounded rather than truncated, and floored at one second: a note that was
  /// held for a moment is "0:01", because a note that exists cannot be nothing
  /// long — and 0:00 beside a play button reads as a broken recording.
  Duration? get _total {
    final ms = durationMs;
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
    final ticks = positionStream;
    if (playing && ticks != null) {
      return StreamBuilder<Duration>(
        stream: ticks,
        builder: (_, snap) =>
            Text(_clock(snap.data ?? Duration.zero), style: style),
      );
    }
    final total = _total;
    return total == null ? null : Text(_clock(total), style: style);
  }

  @override
  Widget build(BuildContext context) {
    final time = _time();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onToggle,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: MilesColors.tint(MilesColors.cream50, 0.15, over: bubble),
              shape: BoxShape.circle,
            ),
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: MilesColors.cream50,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Pseudo-waveform (visual only)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            18,
            (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 2.5,
              height: 8 + ((i * 7) % 18).toDouble(),
              decoration: BoxDecoration(
                color: MilesColors.cream50.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        // Both the gap and the label go, so an unlabelled note keeps exactly
        // the spacing it has today rather than gaining a hole where the time
        // would have been.
        if (time != null) ...[const SizedBox(width: 8), time],
        const SizedBox(width: 8),
        SaveMediaButton(
          size: 16,
          color: MilesColors.taupe,
          onSave: () => SaveMediaService.saveVoiceToVault(
              url: url, senderName: senderName,),
        ),
      ],
    );
  }
}
