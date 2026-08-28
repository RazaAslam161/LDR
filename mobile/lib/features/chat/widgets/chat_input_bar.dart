import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/document_picker_service.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_draft_store.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/voice_peaks.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

/// Chat input bar with three actions: text, image attach, hold-to-record voice.
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    required this.coupleId, required this.onSendText, required this.onSendMedia, required this.onSendFiles, required this.onSendVoice, required this.onSendVideo, required this.onFlingGif, required this.onPickGif, super.key,
    this.onChanged,
    this.replyingTo,
    this.onCancelReply,
    this.editingMessage,
    this.onCancelEdit,
    this.onClearConversation,
  });

  final String coupleId;
  final Future<void> Function(String text) onSendText;

  /// A whole gallery pick — photos and videos together, in pick order. Not a
  /// Future: these are handed to the send queue and are on screen before the
  /// first upload starts, so there is nothing here to wait on.
  final void Function(List<PickedMedia> items) onSendMedia;

  /// A whole document pick. Same contract as [onSendMedia]: handed to the send
  /// queue, on screen before the first byte moves.
  final void Function(List<PickedDocument> docs) onSendFiles;
  /// The id is minted by the bar, not the send path, so a retry of the SAME
  /// recording reuses it and the second insert conflicts instead of duplicating.
  final Future<void> Function(File voice, String id, String? peaks) onSendVoice;
  final Future<void> Function(File video) onSendVideo;

  /// A GIF/sticker picked from the phone keyboard — flung (rises on both phones).
  final Future<void> Function(File gif) onFlingGif;

  /// Open the in-app GIPHY picker to send a GIF into the chat.
  final VoidCallback onPickGif;

  /// Called as the user types (used to broadcast the typing indicator).
  final ValueChanged<String>? onChanged;

  /// The message being replied to (shows a quoted bar above the input).
  final Message? replyingTo;

  /// The message being edited, if any. Non-null swaps the bar into edit
  /// mode: the field is seeded with the current text and [onSendText]
  /// means "save this edit" rather than "send a new message".
  final Message? editingMessage;
  final VoidCallback? onCancelEdit;
  final VoidCallback? onCancelReply;

  /// Clears the conversation on THIS device only (local + instant). The
  /// partner's chat is untouched. When null, the clear button is hidden.
  final Future<void> Function()? onClearConversation;

  /// True while a voice note is being recorded here.
  ///
  /// On the widget, not in the State, because the thing that needs the
  /// answer is the shell - and the State is exactly what the shell's own
  /// tab change destroys. Asking the bar after the fact is asking an
  /// object that no longer exists. Same shape as PipMode.active and
  /// AppLock.locked, which the shell already reads for the same reason.
  static final ValueNotifier<bool> recording = ValueNotifier<bool>(false);

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _text = TextEditingController();
  static const _uuid = Uuid();
  final _recorder = AudioRecorder();
  bool _sending = false;
  bool _recording = false;
  String? _currentRecordingPath;

  bool get _hasText => _text.text.trim().isNotEmpty;
  bool _lastHasText = false;

  /// Debounce for writing the draft. A platform round trip per keystroke is a
  /// cost the typing itself should not have to carry.
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    _restoreDraft();
    _lastHasText = _hasText;
    // Rebuild the moment text goes empty↔non-empty so the send (✈) icon
    // appears immediately instead of waiting for an unrelated rebuild.
    _text.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(ChatInputBar old) {
    super.didUpdateWidget(old);
    // An edit starting or ending swaps what is in the field, and it happens
    // with the couple UNCHANGED — so it has to run before the early return
    // below, not after it.
    if (widget.editingMessage?.id != old.editingMessage?.id) {
      final now = widget.editingMessage;
      // The half-typed message is not collateral. An edit is a detour, so what
      // was in the field is held and put back when the detour ends — otherwise
      // tapping edit silently destroys whatever the user was writing.
      if (now != null) {
        _draftBeforeEdit = _text.text;
        _text.text = now.body ?? '';
      } else {
        _text.text = _draftBeforeEdit ?? '';
        _draftBeforeEdit = null;
      }
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    }
    if (old.coupleId == widget.coupleId) return;
    // A different couple on the same handset (an account switch) must neither
    // inherit the previous one's draft nor lose it.
    unawaited(ChatDraftStore.save(old.coupleId, _text.text));
    _text.clear();
    _restoreDraft();
  }

  /// What was in the field when an edit began, restored when it ends.
  String? _draftBeforeEdit;

  /// Put back whatever was typed and not sent.
  ///
  /// Synchronous whenever this process already holds the draft, which is the
  /// ordinary case — a tab change and the disguise cover both dispose this
  /// State without ending the process — so the text is there in the first
  /// frame rather than appearing a moment after it.
  void _restoreDraft() {
    // Any save queued by the caller's _text.clear() is about the couple we are
    // leaving, and would otherwise land on the one we are arriving at.
    _draftTimer?.cancel();
    final cached = ChatDraftStore.peek(widget.coupleId);
    if (cached != null) {
      _setText(cached);
      return;
    }
    unawaited(ChatDraftStore.load(widget.coupleId).then((draft) {
      // The disk read raced the user; the user wins.
      if (!mounted || draft == null || _text.text.isNotEmpty) return;
      _setText(draft);
    }),);
  }

  /// Caret after the restored text, and nothing left marked as composing — the
  /// field is showing settled text, not something the keyboard is mid-way
  /// through and may replace.
  void _setText(String body) {
    _text.value = TextEditingValue(
      text: body,
      selection: TextSelection.collapsed(offset: body.length),
    );
  }

  void _onTextChanged() {
    final h = _hasText;
    if (h != _lastHasText) {
      _lastHasText = h;
      if (mounted) setState(() {});
    }
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 250), _saveDraft);
  }

  /// Reads the field when it runs rather than capturing the text when it was
  /// scheduled, so a save that lands after a send writes the cleared field.
  void _saveDraft() {
    _draftTimer?.cancel();
    unawaited(ChatDraftStore.save(widget.coupleId, _text.text));
  }

  @override
  void dispose() {
    // Written HERE and not only on the debounce: this State is disposed on
    // every tab change and every time the cover goes up, and someone who types
    // and leaves at once would outrun the timer. Before _text.dispose(),
    // because it reads the field.
    _saveDraft();
    _text.removeListener(_onTextChanged);
    _text.dispose();
    // Lowered here too: _stopRecording is a setState and cannot run from
    // dispose, so a bar torn down mid-hold would leave the flag raised
    // for the life of the process - and the shell would never move
    // anyone home again.
    ChatInputBar.recording.value = false;
    // Same reason as the flag above: dispose cannot await, but an uncancelled
    // subscription outlives this State and would pour the next recording's
    // samples into a buffer belonging to a bar that no longer exists.
    unawaited(_cancelAmplitude());
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
      // Said out loud like every other picker here — this was the one attach
      // path that failed without a word.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send that GIF.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    _text.clear();
    // The draft dies with the send, and it dies BEFORE the await: this State is
    // disposed the moment the user leaves, and a draft still holding a body
    // that already went is one that comes back and gets sent a second time.
    _draftTimer?.cancel();
    unawaited(ChatDraftStore.clear(widget.coupleId));
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
      // Anything the platform had no codec for at all. Named, because "unable
      // to send" with no reason is what sent the user looking for the bug.
      final skipped = PhotoPickerService.takeRejectedFormats();
      if (skipped.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              skipped.length == 1
                  ? "This phone can't read .${skipped.first} files"
                  : "This phone can't read these: "
                      '${skipped.map((e) => '.$e').join(', ')}',
            ),
          ),
        );
      }
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

  /// Documents, through the storage provider rather than the gallery.
  ///
  /// The size check is here rather than left to the upload: couple_files
  /// rejects anything over its limit with a storage error, which reaches the
  /// user as a bubble that says "didn't send" and no reason at all.
  Future<void> _pickDocuments() async {
    try {
      final docs = await DocumentPickerService.pick();
      if (docs.isEmpty) return;
      final small = docs
          .where((d) => d.size <= DocumentPickerService.maxBytes)
          .toList();
      if (small.length != docs.length && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Files over '
                  '${DocumentPickerService.formatBytes(DocumentPickerService.maxBytes)}'
                  ' were skipped.',),),
        );
      }
      if (small.isNotEmpty) widget.onSendFiles(small);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not attach that file.')),
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
          ListTile(
            leading: const Icon(Icons.attach_file,
                color: MilesColors.cream50,),
            title: const Text('Document',
                style: TextStyle(color: MilesColors.cream50),),
            subtitle: const Text('PDFs, docs, anything on the phone',
                style: TextStyle(color: MilesColors.taupe, fontSize: 11.5),),
            onTap: () {
              Navigator.pop(context);
              _pickDocuments();
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

  /// Levels for the waveform, one per amplitude tick, in 0..1.
  ///
  /// Plain field with no setState: nothing on screen draws these while the note
  /// is being held. Notifying at the sampling rate would rebuild the whole
  /// input bar ten times a second to change nothing a user can see — the same
  /// reasoning already written over positionStream in voice_note_bubble.dart.
  final List<double> _levels = [];
  StreamSubscription<Amplitude>? _amplitude;

  /// dBFS in, 0..1 out, against a -45 floor rather than the theoretical -160.
  ///
  /// Lifted from recorder_cover.dart, which explains why: everything below -45
  /// is room noise, and a waveform that reacts to room noise looks like a toy.
  /// Kept absolute rather than normalised per note, because the column this
  /// feeds documents 255 as "full scale" — the painter is where a quiet note
  /// gets scaled up to fill its bubble.
  static const double _dbFloor = 45;

  /// Cancelled from every exit path, and that is not belt-and-braces.
  ///
  /// record's onAmplitudeChanged hands back ONE broadcast stream per recorder
  /// and keeps it open across stop(); only the polling timer stops. A
  /// subscription left over from one note therefore goes on appending the NEXT
  /// note's samples to a buffer that already holds the first one, and both
  /// notes end up drawn with the wrong shape.
  Future<void> _cancelAmplitude() async {
    final sub = _amplitude;
    _amplitude = null;
    await sub?.cancel();
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

      // Subscribed BEFORE start(), and the order is the point. The stream is
      // inert until the recorder is actually running, so nothing is lost by
      // being early — whereas subscribing after start() puts a throwing call
      // between a live recorder and the flag the shell reads, and the catch
      // below would then report "could not start" over a microphone that is
      // still hot.
      _levels.clear();
      _amplitude = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen(_onAmplitude);

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
      ChatInputBar.recording.value = true;
    } catch (_) {
      // Leave nothing running. A recorder that started and then threw on the
      // way out keeps the microphone open, and a raised `recording` flag makes
      // the shell refuse to move anyone home for the life of the process.
      await _cancelAmplitude();
      try {
        await _recorder.stop();
      } on Exception {
        // Already stopped, or never started. Either way the next line is what
        // matters, and there is nothing a user could act on here.
      }
      ChatInputBar.recording.value = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start recording.')),
        );
      }
    }
  }

  void _onAmplitude(Amplitude a) {
    _levels.add(((a.current + _dbFloor) / _dbFloor).clamp(0.0, 1.0));
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    if (!_recording) return;
    final path = _currentRecordingPath;
    await _cancelAmplitude();
    try {
      await _recorder.stop();
    } catch (_) {
      // ignore — already stopped
    }
    // Read before the clear, so a note that is about to be sent keeps the
    // shape that was actually recorded for it.
    final peaks = VoicePeaks.encode(_levels);
    _levels.clear();
    setState(() {
      _recording = false;
      _currentRecordingPath = null;
    });
    ChatInputBar.recording.value = false;
    if (cancel || path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    await _sendVoice(file, peaks);
  }

  /// Hand a finished recording to the chat.
  ///
  /// The catch is the point of this method existing. The upload throws on any
  /// dead connection and nothing here caught it, so it left through main.dart's
  /// platformDispatcher handler: the note was gone and the user was told
  /// nothing. Failing to START a recording has always said so (:325).
  /// [id] is minted once per recording and REUSED by the retry below.
  ///
  /// Without it the server minted a fresh id per attempt, so a note whose row
  /// had actually landed — response lost on a bad connection, which is exactly
  /// when the retry gets tapped — was written a second time and appeared twice
  /// on both phones. `sendVoice` now treats a primary-key conflict as success,
  /// but only if both attempts carry the SAME id, which is what this threads.
  ///
  /// [peaks] is a parameter for the same reason and not a field. The retry is
  /// tapped from a snackbar that outlives the recording, so a field would have
  /// been overwritten by whatever was recorded in between — and note A would be
  /// re-sent carrying note B's waveform, permanently and silently.
  Future<void> _sendVoice(File file, String? peaks, {String? id}) async {
    final sendId = id ?? _uuid.v4();
    setState(() => _sending = true);
    try {
      await widget.onSendVoice(file, sendId, peaks);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("That voice note didn't send."),
          // The recording is still on disk, so this offers the note itself
          // rather than an apology for having lost it.
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _sendVoice(file, peaks, id: sendId),
          ),
        ),
      );
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
            // Never both: an edit REPLACES a body, so a reply target attached
            // to it would have nowhere to go.
            if (widget.editingMessage != null)
              _EditBar(onCancel: widget.onCancelEdit)
            else if (widget.replyingTo != null)
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
                          // A ceiling, not a counter: maxLength would paint a
                          // "0/20000" under the composer, which is noise on a
                          // chat. This only stops a paste nobody types.
                          //
                          // Encrypting the body put base64 ciphertext on the
                          // realtime broadcast BESIDE the plaintext, so a
                          // message now costs roughly 2.3x its length on that
                          // wire against Supabase Free's 256 KB broadcast cap.
                          // Past it the broadcast is rejected with no retry and
                          // no user-visible signal, and the message arrives a
                          // beat later over the database instead. 20k
                          // characters is far above anything a person writes
                          // and far below the cap either way.
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(20000),
                          ],
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

/// The composer wearing its edit state. Deliberately shaped like [_ReplyBar]
/// — same height, same rule down the left — because it occupies the same slot
/// and a differently-sized banner would make the whole bar jump.
class _EditBar extends StatelessWidget {
  const _EditBar({this.onCancel});
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
            left: BorderSide(color: MilesColors.gilt, width: 3),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 16, color: MilesColors.gilt),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Editing message',
                  style: TextStyle(color: MilesColors.gilt, fontSize: 13),),
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
