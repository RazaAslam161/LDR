import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The bubble a snap arrives in: it says what it is and nothing else.
///
/// Deliberately blind. It is handed the whole [Message] — path included — and
/// renders none of it: no thumbnail, no blur, no blur-hash, and a fixed width
/// whatever the media, because an aspect ratio is itself a hint and a portrait
/// tile in this app is not a neutral one. Anyone glancing over a shoulder
/// learns "photo" and no more, which is the entire point of the gate.
///
/// Opening it, and saving it from the viewer afterwards, are two separate
/// deliberate acts. The message persists either way — this keeps rendering
/// after it has been opened; nothing here expires.
class GatedMediaBubble extends StatelessWidget {
  const GatedMediaBubble({
    required this.message,
    super.key,
    this.onTap,
    this.onRetry,
    this.busy = false,
  });

  final Message message;
  final VoidCallback? onTap;
  final VoidCallback? onRetry;

  /// Work the caller owns rather than the send queue — a private video's URL
  /// being signed before the player can open.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final video = message.kind == 'video';
    final failed = message.sendStatus == SendStatus.failed;
    final waiting = busy || message.sendStatus == SendStatus.sending;
    // What it is, never how big or how long: neither the byte count nor the
    // duration is known without fetching the media, which is what the gate
    // exists to postpone.
    final subtitle = failed
        ? "Didn't send · tap to retry"
        : waiting
            ? 'One moment…'
            : 'Tap to view';

    return Material(
      color: MilesColors.surface2,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: failed ? onRetry : (waiting ? null : onTap),
        child: Container(
          width: 200,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: failed
                  ? MilesColors.ember
                  : MilesColors.gilt.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: MilesColors.ember,
                ),
                child: waiting
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: MilesColors.cream50,),
                      )
                    : Icon(
                        failed
                            ? Icons.refresh_rounded
                            : video
                                ? Icons.videocam_rounded
                                : Icons.photo_camera_rounded,
                        color: MilesColors.cream50,
                        size: 20,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(video ? 'Video' : 'Photo',
                        style: const TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                          color: failed ? MilesColors.ember : MilesColors.taupe,
                          fontSize: 12,
                        ),),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
