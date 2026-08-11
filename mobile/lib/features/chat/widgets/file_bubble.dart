import 'package:flutter/material.dart';
import 'package:miles/core/services/document_picker_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:url_launcher/url_launcher.dart';

/// A document in the conversation: what it is called, how big it is, and a tap
/// that opens it.
///
/// Nothing is rendered from the file itself — a document has no thumbnail, and
/// fetching 25MB to find that out would be worse than the wait it replaced. It
/// signs on tap instead of with the page, because unlike a photo the bubble
/// needs no URL to draw itself.
class FileBubble extends StatefulWidget {
  const FileBubble({required this.message, super.key});

  final Message message;

  @override
  State<FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<FileBubble> {
  bool _opening = false;

  Future<void> _open() async {
    final path = widget.message.filePath;
    if (path == null) return;
    setState(() => _opening = true);
    final url = await ChatRepository.signedFileUrl(path);
    if (!mounted) return;
    setState(() => _opening = false);
    // ?download= makes Storage send Content-Disposition: attachment, so the
    // handler saves the file under its real name instead of rendering it or
    // saving it as the object's random one.
    final ok = url != null &&
        await launchUrl(
          Uri.parse('$url&download=${Uri.encodeComponent(_name)}'),
          mode: LaunchMode.externalApplication,
        );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open that file.')),
      );
    }
  }

  String get _name {
    final n = (widget.message.body ?? '').trim();
    return n.isEmpty ? 'File' : n;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final failed = m.sendStatus == SendStatus.failed;
    final busy = _opening || m.sendStatus == SendStatus.sending;
    final size = m.fileSize;
    final subtitle = failed
        ? "Didn't send · tap to retry"
        : busy
            ? 'One moment…'
            : (size == null
                ? 'Tap to open'
                : '${DocumentPickerService.formatBytes(size)} · tap to open');

    return Material(
      color: MilesColors.surface2,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: failed
            ? () => ChatSendQueue.instance.retry(m.id)
            : (busy ? null : _open),
        child: Container(
          width: 220,
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
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: MilesColors.cream50,),
                      )
                    : Icon(
                        failed
                            ? Icons.refresh_rounded
                            : Icons.insert_drive_file_outlined,
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
                    Text(_name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
