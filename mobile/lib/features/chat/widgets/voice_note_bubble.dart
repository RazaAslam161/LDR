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
      // Reaching the end is not a pause: the note is no longer the current
      // one, so its bubble goes back to a play icon at the moment the audio
      // stops rather than sitting on a pause icon over silence.
      if (s.processingState == ProcessingState.completed) _currentId = null;
      notifyListeners();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _sub;

  /// The message whose note is loaded, or null when nothing is.
  String? _currentId;

  /// Whether THIS message is the one being heard right now.
  bool isPlaying(String messageId) =>
      _currentId == messageId && _player.playing;

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
    super.key,
  });

  final String url;
  final bool playing;
  final VoidCallback onToggle;
  final String senderName;

  /// The fill of the bubble this sits inside — the controls resolve their
  /// tint against it rather than washing over it.
  final Color bubble;

  @override
  Widget build(BuildContext context) {
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
