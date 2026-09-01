import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/voice_peaks.dart';
import 'package:miles/features/chat/widgets/voice_note_bubble.dart';

final DateFormat _sheetStamp = DateFormat('EEEE, MMM d · h:mm a');

/// The message a reply is answering, when the conversation cannot scroll to it.
///
/// The chat loads the newest 300 rows and no further back, so a reply to
/// something older quotes a message this device has never held. Tapping that
/// quote could reasonably do nothing — which is precisely the complaint the
/// jump exists to fix, so it does this instead: fetch the one row and show it.
///
/// A voice note is playable here rather than described, because "someone
/// replied to one of my five voice notes and neither of us knows which" is the
/// case this whole feature was asked for.
Future<void> showOriginalMessageSheet(
  BuildContext context, {
  required Message message,
  required String authorName,
  required VoiceNotePlayer voice,
  required Color bubble,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: MilesColors.surface1,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Original message',
              style: TextStyle(
                color: MilesColors.taupe,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              authorName,
              style: const TextStyle(
                color: MilesColors.gilt,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _sheetStamp.format(message.createdAt),
              style: const TextStyle(
                color: MilesColors.faint,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            _OriginalBody(message: message, voice: voice, bubble: bubble),
            const SizedBox(height: 16),
            const Text(
              'This one is older than the conversation loaded on this phone, '
              'so there is nowhere to scroll to.',
              style: TextStyle(
                color: MilesColors.faint,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _OriginalBody extends StatelessWidget {
  const _OriginalBody({
    required this.message,
    required this.voice,
    required this.bubble,
  });

  final Message message;
  final VoiceNotePlayer voice;
  final Color bubble;

  @override
  Widget build(BuildContext context) {
    if (message.deletedForEveryone) {
      return const Text(
        'This message was deleted.',
        style: TextStyle(
          color: MilesColors.taupe,
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final url = message.voiceUrl;
    if (message.kind == 'voice' && url != null) {
      return ListenableBuilder(
        listenable: voice,
        builder: (context, _) => VoiceNoteBubble(
          url: url,
          playing: voice.isPlaying(message.id),
          onToggle: () => unawaited(voice.toggle(message.id, url)),
          senderName: 'them',
          bubble: bubble,
          durationMs: message.voiceDurationMs,
          positionStream: voice.positionStream,
          peaks: VoicePeaks.decode(message.voicePeaks),
          messageId: message.id,
          speed: voice.speed,
          current: voice.isCurrent(message.id),
          onCycleSpeed: () => unawaited(voice.cycleSpeed()),
          playerTotal: voice.totalOf(message.id),
          onSeek: (at) => unawaited(voice.seek(message.id, url, at)),
          onScrub: ({required active}) =>
              voice.scrubbing.value = active ? message.id : null,
        ),
      );
    }

    final body = message.body?.trim();
    if (message.kind == 'text' && body != null && body.isNotEmpty) {
      return Text(
        body,
        style: const TextStyle(
          color: MilesColors.cream50,
          fontSize: 15,
          height: 1.4,
        ),
      );
    }

    // Photos, videos and documents: named rather than rendered. Opening the
    // full viewer from here would need the conversation's whole media set,
    // which is the screen's to build and not this sheet's.
    return Text(
      message.previewText(),
      style: const TextStyle(color: MilesColors.cream50, fontSize: 15),
    );
  }
}
