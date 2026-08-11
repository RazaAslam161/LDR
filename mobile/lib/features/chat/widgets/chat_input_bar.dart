import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Chat input bar with three actions: text, image attach, hold-to-record voice.
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    required this.coupleId, required this.onSendText, required this.onSendMedia, required this.onSendVoice, required this.onSendVideo, required this.onFlingGif, required this.onPickGif, super.key,
    this.onChanged,
    this.replyingTo,
    this.onCancelReply,
    this.onClearConversation,
  });

  final String coupleId;
  final Future<void> Function(String text) onSendText;

  /// A whole gallery pick — photos and videos together, in pick order. Not a
  /// Future: these are handed to the send queue and are on screen before the
  /// first upload starts, so there is nothing here to wait on.
  final void Function(List<PickedMedia> items) onSendMedia;
  final Future<void> Function(File voice) onSendVoice;
  final Future<void> Function(File video) onSendVideo;

  /// A GIF/sticker picked from the phone keyboard — flung (rises on both phones).
  final Future<void> Function(File gif) onFlingGif;

  /// Open the in-app GIPHY picker to send a GIF into the chat.
  final VoidCallback onPickGif;

  /// Called as the user types (used to broadcast the typing indicator).
  final ValueChanged<String>? onChanged;

  /// The message being replied to (shows a quoted bar above the input).
  final Message? replyingTo;
  final VoidCallback? onCancelReply;

  /// Clears the conversation on THIS device only (local + instant). The
  /// partner's chat is untouched. When null, the clear button is hidden.
  final Future<void> Function()? onClearConversation;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _text = TextEditingController();
  final _recorder = AudioRecorder();
  bool _sending = false;
  bool _recording = false;
  String? _currentRecordingPath;

  bool get _hasText => _text.text.trim().isNotEmpty;
  bool _lastHasText = false;

  @override
  void initState() {
    super.initState();
    // Rebuild the moment text goes empty↔non-empty so the send (✈) icon
    // appears immediately instead of waiting for an unrelated rebuild.
    _text.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final h = _hasText;
    if (h != _lastHasText) {
      _lastHasText = h;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _recorder.dispose();
    super.dispose();
  }

  /// A GIF/sticker/image inserted from the phone's keyboard (Gboard GIF panel).
  /// Saved as-is and sent as an image message — GIFs stay animated (sendImage
  /// uploads the raw file without recompressing).
  Future<void> _onKeyboardContent(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null) return;
    try {
      final mime = content.mimeType.toLowerCase();
      final ext = mime.contains('gif')
          ? 'gif'
          : mime.contains('png')
              ? 'png'
              : mime.contains('webp')
                  ? 'webp'
                  : 'jpg';
      final dir = await getTemporaryDirectory();
      final f =
          File('${dir.path}/kbd_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await f.writeAsBytes(data);
      setState(() => _sending = true);
      await widget.onFlingGif(f); // rises on both phones like a mood burst
    } catch (_) {
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    _text.clear();
    setState(() => _sending = true);
    try {
      await widget.onSendText(t);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Opens the fast in-app camera (live filters + one-tap send) instead of the
  /// slow system camera. Uses the bar's own context (valid after the attach
  /// sheet pops).
  void _openRapidCamera() {
    context.push('/app/rapid-camera', extra: {
      'coupleId': widget.coupleId,
      'myUid': SupabaseService.currentUserId ?? '',
    },);
  }

  /// Photos and videos, many at a time, straight into the conversation.
  ///
  /// No _sending spinner on purpose: the pick returns and the bubbles are
  /// already there. A spinner would be claiming the user is waiting on
  /// something they are not.
  Future<void> _pickMedia() async {
    try {
      final items = await PhotoPickerService.pickMedia();
      if (items.isEmpty) return;
      widget.onSendMedia(items);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not attach that.')),
        );
      }
    }
  }

  Future<void> _recordVideo() async {
    try {
      final file = await PhotoPickerService.pickVideo(source: ImageSource.camera);
      if (file == null) return;
      setState(() => _sending = true);
      await widget.onSendVideo(file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not attach that video.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showAttachSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: ColoredBox(
          color: MilesColors.surface1,
          child: SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading:
                const Icon(Icons.gif_box_outlined, color: MilesColors.blush),
            title: const Text('GIF',
                style: TextStyle(color: MilesColors.cream50),),
            subtitle: const Text('Search & send an animated GIF',
                style: TextStyle(color: MilesColors.taupe, fontSize: 11.5),),
            onTap: () {
              Navigator.pop(context);
              widget.onPickGif();
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined,
                color: MilesColors.cream50,),
            title: const Text('Camera',
                style: TextStyle(color: MilesColors.cream50),),
            onTap: () {
              Navigator.pop(context);
              _openRapidCamera();
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined,
                color: MilesColors.cream50,),
            title: const Text('Photos & videos',
                style: TextStyle(color: MilesColors.cream50),),
            subtitle: const Text('Pick as many as you like — up to 50',
                style: TextStyle(color: MilesColors.taupe, fontSize: 11.5),),
            onTap: () {
              Navigator.pop(context);
              _pickMedia();
            },
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined,
                color: MilesColors.emberSoft,),
            title: const Text('Record video',
                style: TextStyle(color: MilesColors.cream50),),
            onTap: () {
              Navigator.pop(context);
              _recordVideo();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied.')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          bitRate: 96000,
        ),
        path: path,
      );
      setState(() {
        _recording = true;
        _currentRecordingPath = path;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start recording.')),
        );
      }
    }
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    if (!_recording) return;
    final path = _currentRecordingPath;
    try {
      await _recorder.stop();
    } catch (_) {
      // ignore — already stopped
    }
    setState(() {
      _recording = false;
      _currentRecordingPath = null;
    });
    if (cancel || path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    setState(() => _sending = true);
    try {
      await widget.onSendVoice(file);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyingTo != null)
              _ReplyBar(
                  message: widget.replyingTo!, onCancel: widget.onCancelReply,),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Attach button
                CircleIconButton(
                  icon: Icons.add,
                  onTap: _sending ? null : _showAttachSheet,
                ),
                const SizedBox(width: 6),

                // Text field or recording indicator
                Expanded(
                  child: _recording
                      ? Container(
                          height: 48,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: MilesColors.surface1,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          alignment: Alignment.centerLeft,
                          child: const Row(
                            children: [
                              Icon(Icons.fiber_manual_record,
                                  color: MilesColors.ember, size: 16,),
                              SizedBox(width: 8),
                              Text(
                                'Slide up to cancel · release to send',
                                style: TextStyle(
                                    color: MilesColors.cream50, fontSize: 13,),
                              ),
                            ],
                          ),
                        )
                      : TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 5,
                          onChanged: widget.onChanged,
                          // Phone's built-in emoji work automatically; this lets
                          // the keyboard's GIF/sticker picker (Gboard) insert
                          // straight into chat.
                          contentInsertionConfiguration:
                              ContentInsertionConfiguration(
                            allowedMimeTypes: const [
                              'image/gif',
                              'image/webp',
                              'image/png',
                              'image/jpeg',
                            ],
                            onContentInserted: _onKeyboardContent,
                          ),
                          style: const TextStyle(color: MilesColors.cream50),
                          decoration: InputDecoration(
                            hintText: 'Message…',
                            hintStyle: TextStyle(
                                color:
                                    MilesColors.cream50.withValues(alpha: 0.4),),
                            filled: true,
                            fillColor: MilesColors.surface1,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12,),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 6),

                // Clear conversation — local & instant, partner unaffected.
                if (widget.onClearConversation != null) ...[
                  CircleIconButton(
                    icon: Icons.delete_sweep_outlined,
                    onTap: (_sending || _recording)
                        ? null
                        : () => widget.onClearConversation!.call(),
                  ),
                  const SizedBox(width: 6),
                ],

                // Mic button (when no text) OR Send button (when text)
                if (_sending) const SizedBox(
                        width: 44,
                        height: 44,
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: MilesColors.cream50,),
                        ),
                      ) else GestureDetector(
                        onLongPressStart: (_) => _startRecording(),
                        onLongPressEnd: (_) => _stopRecording(),
                        onTap: _hasText ? _sendText : null,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _recording ? MilesColors.ember : null,
                            gradient: _recording ? null : MilesGradients.cta,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _recording
                                ? Icons.stop_rounded
                                : (_hasText
                                    ? Icons.send_rounded
                                    : Icons.mic_rounded),
                            color: MilesColors.cream50,
                            size: 22,
                          ),
                        ),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.message, this.onCancel});
  final Message message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
    decoration: BoxDecoration(
      color: MilesColors.surface1,
      borderRadius: BorderRadius.circular(12),
      border: const Border(
        left: BorderSide(color: MilesColors.blush, width: 3),
      ),
    ),
    child: Row(
      children: [
        const Icon(Icons.reply, size: 16, color: MilesColors.blush),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Replying to',
                  style: TextStyle(color: MilesColors.blush, fontSize: 11),),
              Text(
                message.previewText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: MilesColors.cream50, fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: MilesColors.taupe),
          onPressed: onCancel,
        ),
      ],
    ),
      ),
    );
  }
}

class CircleIconButton extends StatelessWidget {
  const CircleIconButton({required this.icon, super.key, this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MilesColors.surface1,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: MilesColors.cream50, size: 22),
        ),
      ),
    );
  }
}
