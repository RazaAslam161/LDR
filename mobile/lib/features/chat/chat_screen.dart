import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/app/root_scaffold_key.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/links/link_open.dart';
import 'package:miles/core/links/link_scan.dart';
import 'package:miles/core/links/link_target.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/services/document_picker_service.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/ui/mood.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/animated_mood.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_media_source.dart';
import 'package:miles/features/chat/chat_reactions.dart';
import 'package:miles/features/chat/chat_receipts.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/unread_tally.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_selection.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:miles/features/chat/media_album.dart';
import 'package:miles/features/chat/message_reveal.dart';
import 'package:miles/features/chat/theme/chat_backdrop.dart';
import 'package:miles/features/chat/theme/chat_theme.dart';
import 'package:miles/features/chat/theme/chat_theme_controller.dart';
import 'package:miles/features/chat/theme/chat_theme_picker.dart';
import 'package:miles/features/chat/voice_peaks.dart';
import 'package:miles/features/chat/widgets/album_bubble.dart';
import 'package:miles/features/chat/widgets/chat_input_bar.dart';
import 'package:miles/features/chat/widgets/file_bubble.dart';
import 'package:miles/features/chat/widgets/giphy_picker.dart';
import 'package:miles/features/chat/widgets/link_card.dart';
import 'package:miles/features/chat/widgets/media_viewer.dart';
import 'package:miles/features/chat/widgets/measured_row.dart';
import 'package:miles/features/chat/widgets/mood_selector.dart';
import 'package:miles/features/chat/widgets/original_message_sheet.dart';
import 'package:miles/features/chat/widgets/reaction_bar.dart';
import 'package:miles/features/chat/widgets/reaction_chips.dart';
import 'package:miles/features/chat/widgets/selectable_message.dart';
import 'package:miles/features/chat/widgets/typing_indicator.dart';
import 'package:miles/features/chat/widgets/voice_note_bubble.dart';
import 'package:miles/features/safety/report_service.dart';
import 'package:miles/features/safety/safety_sheets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'package:uuid/uuid.dart';


class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final List<Message> _messages = [];
  final Set<String> _ids = {};

  RealtimeChannel? _channel;
  bool _loading = true;
  String? _coupleId;
  Timer? _typingTimer;
  Timer? _tickTimer;
  Timer? _readAckTimer;
  bool _typingActive = false;
  bool _hasNewMessage = false;
  Message? _replyingTo;
  Message? _editingMessage;
  RealtimeChannel? _moodChannel;

  /// Local-only "clear conversation" cutoff: messages at or before this are
  /// hidden on THIS device. Never synced — the partner is unaffected.
  DateTime? _clearedBefore;

  /// Messages picked for a bulk action. Empty means not in selection mode —
  /// there is no separate flag to fall out of sync with the set itself.
  /// Bumped every 5s so time-decayed read receipts refresh without rebuilding
  /// the screen around them.
  final _receiptTick = ValueNotifier<int>(0);

  /// The partner's delivery/read position. Live via realtime, so the sender's
  /// tick updates the moment they ack.
  ///
  /// Seeded from [_ReceiptMemory] before the first frame rather than starting
  /// null, because null renders as a single grey tick on every message in the
  /// conversation — see [_ReceiptMemory] for why that was visible on every
  /// tab change.
  ChatReceipt? _partnerReceipt;
  RealtimeChannel? _receiptChannel;

  final _selection = ChatSelection();
  bool get _selecting => _selection.isActive;

  /// What the bubbles read. Written OPTIMISTICALLY: a tap paints here before
  /// anything touches the network, and nothing that comes back later can
  /// overwrite a change this device has not landed yet.
  final _reactions = ChatReactionStore();

  /// The durable live wire for reactions, beside the broadcast fast path.
  ///
  /// Its own channel rather than a listener bolted onto `receipts:<id>`:
  /// delivery receipts are the one path in this screen that must not be
  /// disturbed, and a second postgres_changes handler on their channel puts
  /// this feature inside their blast radius for no gain.
  RealtimeChannel? _reactionChannel;

  /// One reaction fetch at a time, and one more if anything asked while it ran.
  bool _reactionFetchBusy = false;
  bool _reactionFetchAgain = false;
  bool _subscribing = false; // re-entrancy guard for _subscribe
  bool _reloadScheduled = false; // debounce flag for bulk-DELETE realtime events

  /// How many times this screen has (re)joined its channels. A join that keeps
  /// climbing is a flapping socket, which from the outside looks like nothing.
  int _joinAttempt = 0;

  /// Last traced tick per message. _statusFor runs for every bubble on every
  /// 5s tick, and a trace that re-states 300 unchanged ticks buries the one
  /// that actually moved.
  final Map<String, _MsgStatus> _tracedTick = {};

  final List<_ActiveBurst> _bursts = [];
  int _burstId = 0;
  static const _uuid = Uuid();

  /// Send text with INSTANT feedback: show it locally now (optimistic), push it
  /// to the partner over realtime broadcast (fast), and persist to the DB. All
  /// three carry the same id, so the postgres echo + broadcast dedupe cleanly.
  ///
  /// The insert belongs to [ChatSendQueue] rather than to this screen. It used
  /// to be awaited here under an empty catch, which lost the message twice
  /// over: a failure told nobody, and moving off the chat tab disposed the
  /// screen holding the only copy of the body.
  Future<void> _sendTextFast(String coupleId, String t) async {
    final body = t.trim();
    if (body.isEmpty) return;
    MilesSound.cue(Cue.send);
    final replyId = _takeReplyId();
    final id = _uuid.v4();
    final myUid = SupabaseService.currentUserId;
    final now = DateTime.now();
    if (myUid != null) {
      _onIncoming(Message(
        id: id,
        senderId: myUid,
        createdAt: now,
        body: body,
        replyToId: replyId,
        // Not 'sent' until a row exists: the bubble took the default and the
        // failure was swallowed, so a message that never left the phone drew
        // the same single tick as one the partner already had.
        sendStatus: SendStatus.sending,
      ), source: 'local_send',);
    }
    // The broadcast is the FASTER of the two wires and the one the partner
    // renders from first, so it seals alongside the column rather than after
    // it — encrypting only the row would still put every message across
    // Supabase Realtime in the clear. Sealed against the same row id, so the
    // associated data matches whichever copy the partner opens.
    //
    // Its own encrypt, and therefore its own nonce: two encryptions of one
    // plaintext under one key with DIFFERENT nonces is exactly correct, and
    // threading the blob through the send queue to save a few microseconds
    // would couple three layers together for nothing.
    //
    // 'body' rides the payload under the SAME rule the row does, never
    // unconditionally. During dual-write — which is the resting state, the flag
    // is false — it goes exactly as it always has, and every build in the field
    // keeps rendering this send from the only key it reads. But the flip is
    // documented as one server-side row, and a broadcast that ignored it would
    // null `messages.body` at rest while every message kept crossing Realtime
    // in the clear: the operator would read their own exposure wrong on the
    // strength of half a switch, and the user-facing "chat is not encrypted"
    // copy is retired on that reading.
    unawaited(() async {
      final sealed = await ChatRepository.sealBody(body.trim(), id);
      final omitBody = ChatRepository.omitPlaintext(
        cipherOnly: ReleaseGate.chatCipherOnly,
        sealed: sealed != null,
      );
      await _moodChannel?.sendBroadcastMessage(event: 'msg', payload: {
        'id': id,
        'sender': myUid,
        if (!omitBody) 'body': body,
        if (sealed != null) 'cipher': base64Encode(sealed.blob),
        if (sealed != null) 'nonce': base64Encode(sealed.nonce),
        'createdAt': now.toUtc().toIso8601String(),
        'replyToId': replyId,
      },);
    }(),);
    ChatSendQueue.instance
        .enqueueText(coupleId, body, replyToId: replyId, id: id);
  }

  /// A text message pushed by the partner over broadcast — shown immediately,
  /// then deduped when the slower postgres echo arrives (same id).
  void _onMsgBroadcast(Map<String, dynamic> payload) {
    final m = ChatBroadcastService.messageFrom(payload);
    if (m == null) return;
    // Plaintext (every sender in the field today) goes straight through on this
    // turn — the whole value of the broadcast path is that it beats the
    // database echo, and an await here would hand that lead back.
    if (m.bodyCipher == null) {
      _onIncoming(m, source: 'broadcast');
      return;
    }
    unawaited(ChatRepository.hydrate([m]).then((r) {
      if (mounted) _onIncoming(r.first, source: 'broadcast');
    }),);
  }

  void _sendGifBurst(String url) {
    _moodChannel?.sendBroadcastMessage(event: 'mood', payload: {'gif': url});
    _showGifBurst(url); // also show it on my own screen
  }

  void _onMoodBurst(Map<String, dynamic> payload) {
    final gif = payload['gif']?.toString();
    if (gif != null && gif.isNotEmpty) {
      _showGifBurst(gif);
      return;
    }
    final m = moodByKey(payload['mood']?.toString());
    if (m != null) _showMoodBurst(m);
  }

  void _showMoodBurst(MoodData m) {
    if (!mounted) return;
    setState(() => _bursts.add(_ActiveBurst(_burstId++, mood: m)));
  }

  void _showGifBurst(String url) {
    if (!mounted) return;
    setState(() => _bursts.add(_ActiveBurst(_burstId++, gifUrl: url)));
  }

  void _removeBurst(int id) {
    if (mounted) setState(() => _bursts.removeWhere((b) => b.id == id));
  }

  Future<void> _pickGifBurst() async {
    final url = await showGiphyPicker(context);
    if (url != null) _sendGifBurst(url);
  }

  /// A GIF/sticker picked from the phone's keyboard — upload it (so the partner
  /// can load it) then fling it: it rises on BOTH phones like a mood burst.
  Future<void> _flingGifFile(File f) async {
    final cid = _coupleId;
    if (cid == null) return;
    try {
      final url = await ChatRepository.uploadGif(cid, f);
      // Null is a real failure here, not a cancel: the upload landed but
      // signing died (MediaUrls.sign swallows to null). Without the throw it
      // took the success path with no burst and no word.
      if (url == null) throw StateError('gif sign failed');
      _sendGifBurst(url);
    } catch (_) {
      // The keyboard panel has already closed over the chat, so a fling that
      // dies on upload looked exactly like one that sent.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send that GIF.')),
        );
      }
    }
  }

  /// Open the in-app GIPHY picker and SEND the chosen GIF into the chat as an
  /// animated message (reliable — doesn't depend on the keyboard).
  Future<void> _attachGif() async {
    final url = await showGiphyPicker(context);
    if (url == null) return;
    final cid = _coupleId;
    if (cid == null) return;
    try {
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      // A refusal surfaces exactly like a timeout — the catch below owns the
      // snackbar, where a bare return here dropped the GIF without a word.
      if (res.statusCode != 200) {
        throw HttpException('GIF fetch returned ${res.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final f =
          File('${dir.path}/gif_${DateTime.now().millisecondsSinceEpoch}.gif');
      await f.writeAsBytes(res.bodyBytes);
      _sendImageFast(cid, f);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send that GIF.')),
        );
      }
    }
  }

  /// Send an image with INSTANT feedback: the local file shows as a bubble
  /// immediately (status=sending), then uploads in the background.
  ///
  /// The upload itself belongs to [ChatSendQueue], not to this screen — the
  /// camera can start one with the chat unmounted, and a send must not die with
  /// whatever widget happened to begin it. [_adoptPending] renders whatever the
  /// queue is holding, including sends this screen never saw start.
  void _sendImageFast(String coupleId, File f) {
    ChatSendQueue.instance
        .enqueueImage(coupleId, f, replyToId: _takeReplyId());
    _adoptPending();
  }

  /// Send a whole gallery pick — photos and videos together.
  ///
  /// Nothing is awaited and nothing is re-encoded: all of it is on screen as
  /// bubbles on this frame, and the queue uploads a few at a time behind them.
  /// A failure belongs to its own item, which keeps its file and its retry.
  void _sendMediaBatch(String coupleId, List<PickedMedia> items) {
    if (items.isEmpty) return;
    ChatSendQueue.instance.enqueueAll(coupleId, items,
        replyToId: _takeReplyId(),);
    _adoptPending();
  }

  void _sendDocuments(String coupleId, List<PickedDocument> docs) {
    if (docs.isEmpty) return;
    ChatSendQueue.instance.enqueueFiles(
      coupleId,
      [for (final d in docs) (file: d.file, name: d.name)],
      replyToId: _takeReplyId(),
    );
    _adoptPending();
  }

  /// Mirror the queue's pending sends into the message list.
  ///
  /// Called on mount and whenever the queue changes, so a photo taken from the
  /// shell's camera tab is already a bubble by the time the user reaches the
  /// chat — and a failure becomes a retryable bubble instead of vanishing.
  void _adoptPending() {
    final myUid = SupabaseService.currentUserId;
    final coupleId = _coupleId;
    if (myUid == null || coupleId == null || !mounted) return;

    for (final s in ChatSendQueue.instance.pendingText) {
      if (s.coupleId != coupleId || _syncSendStatus(s.id, s.status)) continue;
      _onIncoming(Message(
        id: s.id,
        senderId: myUid,
        createdAt: DateTime.now(),
        body: s.body,
        sendStatus: s.status,
        replyToId: s.replyToId,
      ), source: 'send_queue',);
    }

    for (final s in ChatSendQueue.instance.pending) {
      if (s.coupleId != coupleId || _syncSendStatus(s.id, s.status)) continue;
      _onIncoming(Message(
        id: s.id,
        senderId: myUid,
        createdAt: DateTime.now(),
        kind: s.kind,
        // A document has no thumbnail, so its bubble is the name — which is
        // what the row will carry once it lands.
        body: s.fileName,
        localPath: s.file.path,
        sendStatus: s.status,
        replyToId: s.replyToId,
        // Carried onto the optimistic bubble so a pick of twenty is ONE grid
        // while it uploads, not twenty bubbles that collapse into a grid the
        // moment the last row lands.
        albumId: s.albumId,
      ), source: 'send_queue',);
    }

    // Anything the queue has finished with is either reconciled by the DB echo
    // or gone; flip a lingering 'sending' bubble so it can't spin forever.
    final live = {
      for (final s in ChatSendQueue.instance.pending) s.id,
      for (final s in ChatSendQueue.instance.pendingText) s.id,
    };
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.sendStatus == SendStatus.sending && !live.contains(m.id)) {
        setState(() =>
            _messages[i] = _messages[i].copyWith(sendStatus: SendStatus.sent),);
      }
    }
  }

  /// Move an existing bubble onto the queue's view of its send.
  ///
  /// Answers whether the bubble was there at all, so the caller can tell an
  /// update from a send it has never rendered.
  bool _syncSendStatus(String id, SendStatus status) {
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return false;
    // A row that has echoed back exists, whatever the call that wrote it went
    // on to report: an insert can land and its response still be lost, and
    // marking that one failed would offer a retry for a message the partner
    // already has.
    if (_messages[i].seq > 0) return true;
    if (_messages[i].sendStatus != status) {
      setState(() => _messages[i] = _messages[i].copyWith(sendStatus: status));
    }
    return true;
  }

  /// One composer, one job. Starting a reply while an edit is open would
  /// silently discard the edit — the field is already holding the message's
  /// text — so the edit is named and kept instead of being thrown away.
  bool _blockedByEdit() {
    if (_editingMessage == null) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Finish or cancel the edit first.')),
    );
    return true;
  }

  void _startReply(Message m) {
    if (m.deletedForEveryone) return;
    if (_blockedByEdit()) return;
    setState(() => _replyingTo = m);
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// How long the SERVER allows an edit. Mirrored here for one reason only —
  /// to avoid offering a button that is already doomed — and never as the
  /// authority. `edit_message` answers `too_late` and that answer is the truth;
  /// a client clock is not evidence about anything.
  static const _editWindow = Duration(minutes: 30);

  bool _canEdit(Message m, String? uid) =>
      m.isMine(uid) &&
      m.kind == 'text' &&
      !m.deletedForEveryone &&
      m.sendStatus == SendStatus.sent &&
      DateTime.now().difference(m.createdAt) < _editWindow;

  void _startEdit(Message m) {
    // An edit replaces a body; a reply target attached to it has nowhere to go.
    setState(() {
      _replyingTo = null;
      _editingMessage = m;
    });
  }

  void _cancelEdit() => setState(() => _editingMessage = null);

  /// Save an edit. Every refusal is the server's, and each gets its own
  /// sentence rather than one shrug — see [ChatRepository.editMessageError].
  Future<void> _saveEdit(Message target, String text) async {
    if (text.trim() == (target.body ?? '').trim()) {
      setState(() => _editingMessage = null);
      return;
    }
    String verdict;
    try {
      verdict = await ChatRepository.editMessage(target.id, text);
    } catch (e) {
      debugPrint('[chat] edit failed: $e');
      verdict = 'network';
    }
    if (!mounted) return;
    if (verdict == 'ok') {
      setState(() => _editingMessage = null);
      // The row is refreshed by the same realtime path a send uses; nothing is
      // patched into _messages by hand, so an edit cannot leave the list
      // disagreeing with the server.
      return;
    }
    // The composer STAYS in edit mode on a refusal, holding the typed text.
    // Dropping out of it would throw the edit away along with the message.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ChatRepository.editMessageError(verdict))),
    );
  }

  /// The id to attach to the next send (and clears the reply state).
  String? _takeReplyId() {
    final id = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    return id;
  }

  /// The reply a voice note was quoting, remembered per send id.
  ///
  /// [_takeReplyId] CONSUMES the reply — it has to, so the next message does
  /// not silently inherit it. But the voice retry re-enters the same send with
  /// the same id, and by then the reply is gone, so a retried note lost the
  /// message it was answering. Keyed by send id, taken once, reused by any
  /// retry of that id.
  final _voiceReplies = <String, String?>{};

  Future<void> _sendVoiceOnce(
      String coupleId, File file, String id, String? peaks,) {
    final replyId = _voiceReplies.putIfAbsent(id, _takeReplyId);
    return ChatRepository.sendVoice(coupleId, file,
        id: id, replyToId: replyId, peaks: peaks,);
  }

  /// Find a loaded message by id (for rendering a quoted reply preview).
  Message? _byId(String? id) {
    if (id == null) return null;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Who wrote the message this one is answering.
  ///
  /// The quote card showed only the preview text, which is most of why nobody
  /// could tell WHICH message a reply belonged to — "yes, exactly" under an
  /// unattributed line is not an answer to anything you can point at.
  String? _replyAuthorFor(Message m, String? uid, String? partnerName) {
    final quoted = _byId(m.replyToId);
    if (quoted == null) return null;
    return quoted.isMine(uid) ? 'You' : (partnerName ?? 'Your partner');
  }

  /// The rows the list is actually showing, by exactly the filters build uses.
  ///
  /// One definition rather than two, and that is the point. A jump has to
  /// resolve a message against what is ON SCREEN: `_messages` still holds rows
  /// this user hid and rows cleared before a local cutoff, so searching it
  /// would send the conversation to a row the list never draws.
  List<ChatRow> _visibleRows(String? uid) {
    final cleared = _clearedBefore;
    return MediaAlbums.rows(
      _messages
          .where((m) => !m.isHiddenFor(uid))
          .where((m) => cleared == null || m.createdAt.isAfter(cleared))
          .toList(),
    );
  }

  /// Which ROW holds this message, or -1.
  ///
  /// Searched across a row's items, not just its newest: media sent together
  /// collapses into one row, so a reply can quote a single photo inside a grid.
  int _rowIndexOf(List<ChatRow> rows, String messageId) {
    for (var i = 0; i < rows.length; i++) {
      for (final m in rows[i].items) {
        if (m.id == messageId) return i;
      }
    }
    return -1;
  }

  /// Row heights, measured as the list lays them out. See [RowOffsets] for why
  /// this exists and why the first attempt (asking the itemBuilder which rows
  /// it built) could not work.
  final RowOffsets _rowOffsets = RowOffsets();

  /// The row being walked to, and the key that lets the last step centre it.
  /// Only ever set on one row at a time, so no GlobalKey is minted for the
  /// other 299.
  String? _revealId;
  final GlobalKey _revealKey = GlobalKey();

  /// The message wearing the landing flash.
  String? _highlightedId;
  Timer? _highlightTimer;

  /// Bumped by anything that invalidates a jump in flight — a finger on the
  /// list, a reload, a clear. A jump that started before the bump is answering
  /// a question about a conversation that no longer exists.
  int _jumpGeneration = 0;
  bool _jumping = false;

  /// Walk the conversation to the message a reply is quoting.
  ///
  /// Each pass measures more of the list than the last, because a sliver lays
  /// its children out in order: one jump towards the target measures every row
  /// in front of it, and the pass after that is exact. Two passes is the normal
  /// case and four is the ceiling.
  ///
  /// Bounded in every direction. `mounted`, the generation counter, and the
  /// target going missing all end it, and the worst case is that nothing moves
  /// and the sheet opens instead — never a spin, and never a fight with the
  /// user's thumb.
  Future<void> _jumpToMessage(String targetId, String? uid) async {
    if (_jumping) return;
    final generation = _jumpGeneration;
    if (_rowIndexOf(_visibleRows(uid), targetId) < 0) {
      await _showOriginal(targetId, uid);
      return;
    }

    _jumping = true;
    setState(() => _revealId = targetId);
    try {
      // The key needs a frame to attach to the row before anything can look
      // for it.
      await WidgetsBinding.instance.endOfFrame;
      for (var pass = 0; pass < 4; pass++) {
        if (!mounted || generation != _jumpGeneration) return;

        // Re-resolved every pass rather than captured once: a message arriving
        // mid-jump inserts at the newest end and pushes every older row's
        // index up by one.
        final rows = _visibleRows(uid);
        final index = _rowIndexOf(rows, targetId);
        if (index < 0) return;
        final ids = [for (final r in rows) r.newest.id];

        if (_revealKey.currentContext != null) break;

        final position = _scroll.position;
        final target = _rowOffsets.centredOffsetFor(
          ids,
          index,
          viewport: position.viewportDimension,
          maxExtent: position.maxScrollExtent,
        );
        final exactAlready = _rowOffsets.isExactFor(ids, index);
        _scroll.jumpTo(target);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || generation != _jumpGeneration) return;
        if (_revealKey.currentContext != null) break;
        // Nothing left to learn and it still is not on screen. Another pass
        // would jump to the same place for the same reason.
        if (exactAlready) break;
      }

      if (!mounted || generation != _jumpGeneration) return;
      if (_revealKey.currentContext != null) {
        await _landOn(targetId, generation);
      } else {
        await _showOriginal(targetId, uid);
      }
    } finally {
      _jumping = false;
      if (mounted) setState(() => _revealId = null);
    }
  }

  /// The last step: centre the row now that it is built, then flash it.
  Future<void> _landOn(String targetId, int generation) async {
    final ctx = _revealKey.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
    if (!mounted || generation != _jumpGeneration) return;
    unawaited(HapticFeedback.lightImpact());
    _highlightTimer?.cancel();
    setState(() => _highlightedId = targetId);
    // Long enough to find with your eyes after the scroll settles, short
    // enough that it is gone before it becomes part of the bubble.
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _highlightedId = null);
    });
  }

  /// The quoted message is not in the loaded window. Fetch the one row and
  /// show it, because doing nothing here is the bug being fixed.
  Future<void> _showOriginal(String id, String? uid) async {
    final couple = _coupleId;
    if (couple == null) return;
    Message? original;
    try {
      original = await ChatRepository.fetchById(couple, id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load that message.')),
      );
      return;
    }
    if (!mounted) return;
    if (original == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That message is no longer in this conversation.'),
        ),
      );
      return;
    }
    final theme = ref.read(chatThemeProvider).theme;
    await showOriginalMessageSheet(
      context,
      message: original,
      authorName: original.isMine(uid)
          ? 'You'
          : (ref.read(sessionProvider).partner?.displayName ?? 'Your partner'),
      voice: _voice,
      bubble: original.isMine(uid) ? theme.myBubble : theme.partnerBubble,
    );
  }

  // Voice recorder
  final _audioRecorder = AudioRecorder();
  final _voice = VoiceNotePlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    realtimeResumed.addListener(_subscribe); // rejoin on any socket reconnect
    // Sends can start anywhere — the shell's camera tab opens with this screen
    // unmounted — so the chat follows the queue rather than owning it.
    ChatSendQueue.instance.addListener(_adoptPending);
    // Same reason as the send queue: a reaction outlives the screen that made
    // it, so the screen follows the outbox rather than owning it.
    ChatReactionOutbox.instance.addListener(_onReactionOutbox);
    _scroll.addListener(_onScroll);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // The shell forces a socket reconnect on resume; the chat channels re-arm
    // via realtimeResumed (onOpen). Just refresh presence so we read as online +
    // in-chat again immediately on return.
    if (s == AppLifecycleState.resumed && _coupleId != null) {
      PresenceService.setOnline(_coupleId!, online: true);
      // Android freezes the process on background, so the socket was dead the
      // whole time. Anything sent during that window exists only in Postgres.
      unawaited(_catchUp(trigger: 'resume'));
      unawaited(_refreshPartnerReceipt(source: 'resume'));
    } else if (s == AppLifecycleState.paused) {
      // Whatever the coalescing window is still holding has to be written now:
      // the broadcast that already moved the partner's tick lives only in their
      // running process, so a cold open on their side reads the row.
      _flushReadAck('background');
    }
  }

  /// Subscribe (or cleanly RE-subscribe) the chat's realtime channels. Idempotent
  /// and re-entrancy-guarded: the old channels are FULLY removed (awaited) before
  /// the new ones join. Supabase's `channel()` never dedupes by topic and
  /// `unsubscribe()` leaves the old channel registered until its async leave
  /// acks — so `unsubscribe()` + immediate re-`channel()` created duplicate-topic
  /// channels whose join was rejected, leaving them joined-but-dead (no live
  /// render). removeChannel() awaits the leave first, so the re-join is clean.
  /// Highest server seq currently on screen. 0 when nothing has landed yet.
  int get _maxSeq =>
      _messages.fold<int>(0, (a, m) => m.seq > a ? m.seq : a);

  /// Tell the partner we have read up to here. Idempotent and monotonic
  /// server-side, so a lost or out-of-order ack cannot un-read anything.
  ///
  /// Two halves. The instant one is a broadcast: it moves their tick in
  /// milliseconds, is never written down, and costs no WAL and no per-row
  /// policy evaluation. The durable one is coalesced onto a trailing timer,
  /// because it used to fire every five seconds for every open chat whether or
  /// not a single message had been read — a heartbeat through postgres_changes,
  /// which is the path Supabase documents as the one that does not scale.
  ///
  /// [flush] for the transitions where the written value has to be right before
  /// this screen stops existing: open, catch-up, background, close.
  void _ackRead(String trigger, {bool flush = false}) {
    final seq = _maxSeq;
    if (seq <= 0) return;
    if (seq > _broadcastReadSeq) {
      _broadcastReadSeq = seq;
      unawaited(_moodChannel
          ?.sendBroadcastMessage(event: 'read', payload: {'seq': seq}),);
    }
    if (flush) {
      _flushReadAck(trigger);
    } else if (seq > _ackedSeq) {
      _readAckTimer ??= Timer(const Duration(seconds: 15),
          () => _flushReadAck('read_coalesced'),);
    }
  }

  /// Write the watermark down, whether or not this seq has been sent before.
  /// `ack_read` takes the max server-side, so re-sending costs one row and
  /// recovers an ack that was dropped — the reason the old timer re-sent an
  /// unchanged seq, except that it did so twelve times a minute rather than at
  /// the four moments where being wrong would outlive the screen.
  void _flushReadAck(String trigger) {
    _readAckTimer?.cancel();
    _readAckTimer = null;
    final seq = _broadcastReadSeq;
    if (seq <= 0) return;
    _ackedSeq = seq;
    unawaited(ChatReceiptRepository.ackRead(seq, trigger: trigger));
  }

  /// Highest seq sent to `chat_receipts`, and the highest the partner has been
  /// told about over broadcast. They differ by whatever the coalescing window
  /// is still holding.
  int _ackedSeq = 0;
  int _broadcastReadSeq = 0;

  /// The partner read up to here, over the ephemeral path. Read implies
  /// delivered.
  void _onReadBroadcast(Map<String, dynamic> payload) {
    final seq = payload['seq'];
    if (seq is! int || seq <= 0) return;
    _applyPartnerReceipt(ChatReceipt(deliveredSeq: seq, readSeq: seq));
  }

  /// The partner's position, clamped upward.
  ///
  /// Four sources feed it now — the broadcast fast path, the receipts channel,
  /// the refetch and [_ReceiptMemory] — and they do not arrive in order. A tick
  /// that has gone green must never turn black again because the slowest of
  /// them answered last with what it knew a moment ago.
  ///
  /// The clamp records BEFORE it renders. An ack landing as the screen is torn
  /// down used to be dropped at the `mounted` check, which is precisely the
  /// receipt the next mount needed most.
  void _applyPartnerReceipt(ChatReceipt r) {
    final prev = _partnerReceipt;
    final delivered = (prev == null || r.deliveredSeq > prev.deliveredSeq)
        ? r.deliveredSeq
        : prev.deliveredSeq;
    final read =
        (prev == null || r.readSeq > prev.readSeq) ? r.readSeq : prev.readSeq;
    final next = ChatReceipt(deliveredSeq: delivered, readSeq: read);
    final key = _receiptKey;
    if (key != null) _ReceiptMemory.remember(key, next);
    if (!mounted) return;
    if (prev != null &&
        delivered == prev.deliveredSeq &&
        read == prev.readSeq) {
      return;
    }
    setState(() => _partnerReceipt = next);
  }

  /// Per couple AND per signed-in user, matching [_clearedKey]: one handset can
  /// carry two accounts, and the second must never inherit the first's ticks.
  String? get _receiptKey {
    final couple = _coupleId;
    final uid = SupabaseService.currentUserId;
    if (couple == null || uid == null) return null;
    return 'chat_receipt_${couple}_$uid';
  }

  Future<void> _refreshPartnerReceipt({required String source}) async {
    // Every caller reaches here across an await, and `ref.read` throws
    // StateError once the element is disposed — leaving the chat while this was
    // in flight was five of the six errors reported from build 40.
    if (!mounted) return;
    final couple = _coupleId;
    final partnerId = ref.read(sessionProvider).partner?.id;
    if (couple == null || partnerId == null) return;
    final prev = _partnerReceipt;
    final r = await ChatReceiptRepository.fetchPartner(couple, partnerId);
    // prev vs next, because "the partner never acked" and "they acked and this
    // device kept the old value" are the same stuck tick from the outside.
    Diag.record(DiagArea.receipt, 'partner_receipt_observed',
        corr: couple,
        fields: {
          'source': source,
          'row_present': r != null,
          'delivered_seq': r?.deliveredSeq,
          'read_seq': r?.readSeq,
          'prev_delivered_seq': prev?.deliveredSeq,
          'prev_read_seq': prev?.readSeq,
        },);
    if (r != null) _applyPartnerReceipt(r);
  }

  /// Pull anything that landed while the socket was down.
  ///
  /// postgres_changes and broadcast are live-only: their cursor is the moment
  /// the topic was joined. A message sent during a gap was emitted into a
  /// socket that no longer existed and is never re-emitted — it was absent
  /// from the list, the screen and _ids, permanently, until the app was killed
  /// and relaunched. Rejoining a channel is not enough; the gap has to be read.
  Future<void> _catchUp({required String trigger}) async {
    final couple = _coupleId;
    if (couple == null) return;
    // Reactions have exactly the gap messages have, and fetchSince does not
    // carry them: both reaction wires are live-only — the broadcast is
    // at-most-once, and a rejoined postgres_changes channel starts its cursor
    // at the join and replays nothing. Without this, a reaction the partner
    // added or took back while the socket was down never appeared for the rest
    // of the screen's life.
    //
    // AFTER the messages have merged, and outside the early return below: the
    // id list is built from _messages, so running it first would miss every
    // reaction on a message this same pass is about to recover — and running
    // it inside the try would skip the commonest case of all, a partner who
    // reacted without sending anything. Not awaited; the rejoin does not wait
    // on a repaint.
    try {
      final missed = await ChatRepository.fetchSince(couple, _maxSeq);
      if (mounted && missed.isNotEmpty) {
        for (final m in missed) {
          _onIncoming(m, fromDb: true, source: 'catchup');
        }
        // We have now genuinely received them; say so, and if the chat is open
        // they are also read.
        unawaited(
            ChatReceiptRepository.ackDelivered(_maxSeq, trigger: trigger),);
        _ackRead(trigger, flush: true);
      }
    } catch (e) {
      debugPrint('[chat] catch-up failed: $e');
    }
    if (trigger != 'chat_open' && mounted) unawaited(_loadReactions(couple));
  }

  Future<void> _subscribe({String trigger = 'rt_resume'}) async {
    final id = _coupleId;
    if (id == null || !mounted || _subscribing) return;
    _subscribing = true;
    final attempt = ++_joinAttempt;
    try {
      final client = SupabaseService.client;
      final old1 = _channel;
      final old2 = _moodChannel;
      _channel = null;
      _moodChannel = null;
      if (old1 != null) {
        try {
          await client.removeChannel(old1);
        } catch (_) {}
      }
      if (old2 != null) {
        try {
          await client.removeChannel(old2);
        } catch (_) {}
      }
      final old3 = _receiptChannel;
      _receiptChannel = null;
      if (old3 != null) {
        try {
          await client.removeChannel(old3);
        } catch (_) {}
      }
      final old4 = _reactionChannel;
      _reactionChannel = null;
      if (old4 != null) {
        try {
          await client.removeChannel(old4);
        } catch (_) {}
      }
      if (!mounted) return;
      _channel = ChatRepository.subscribe(
        id,
        (m) => _onIncoming(m, fromDb: true, source: 'rt_insert'),
        onDelete: _onRemoteDelete,
      );
      _moodChannel = client
          .channel('mood_burst:$id', opts: RealtimeChannelConfig(private: true))
          .onBroadcast(event: 'mood', callback: _onMoodBurst)
          .onBroadcast(event: 'msg', callback: _onMsgBroadcast)
          .onBroadcast(event: 'typing', callback: _onTypingBroadcast)
          .onBroadcast(event: 'read', callback: _onReadBroadcast)
          .onBroadcast(event: 'react', callback: _onReactionBroadcast)
          .onBroadcast(event: 'cleared', callback: _onClearedBroadcast)
          // subscribe() took no status callback, so a CHANNEL_ERROR here was
          // silent: the whole broadcast fast path — typing, the instant msg,
          // cleared — stops and neither phone reports anything.
          .subscribe((status, err) {
        Diag.record(DiagArea.receipt, 'rt_channel_join', corr: id, fields: {
          'topic_kind': 'mood_burst',
          'status': status.name,
          'error_class': err?.runtimeType.toString(),
          'attempt_n': attempt,
        },);
      });
      // Let other screens (e.g. the rapid camera) push the fast-path on THIS
      // live channel instead of creating a duplicate-topic one.
      ChatBroadcastService.active = _moodChannel;

      // The durable half of reactions. Its own channel, deliberately not a
      // second handler on `receipts:<id>` — the tick path is the one thing in
      // this screen that must not be disturbed.
      _reactionChannel = client
          .channel('reactions:$id',
              opts: const RealtimeChannelConfig(private: true),)
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'message_reactions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'couple_id',
              value: id,
            ),
            callback: _onReactionRow,
          )
          .subscribe((status, err) {
        Diag.record(DiagArea.receipt, 'rt_channel_join', corr: id, fields: {
          'topic_kind': 'reactions',
          'status': status.name,
          'error_class': err?.runtimeType.toString(),
          'attempt_n': attempt,
        },);
      });

      // The partner's receipt row, live. Without this the sender's tick only
      // moved when something else happened to rebuild the screen.
      final partnerId = ref.read(sessionProvider).partner?.id;
      if (partnerId != null) {
        _receiptChannel = client
            .channel('receipts:$id', opts: RealtimeChannelConfig(private: true))
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'chat_receipts',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'user_id',
                value: partnerId,
              ),
              callback: (payload) {
                final row = payload.newRecord;
                if (row.isEmpty || !mounted) return;
                final prev = _partnerReceipt;
                final r = ChatReceipt.fromJson(row);
                Diag.record(DiagArea.receipt, 'partner_receipt_observed',
                    corr: id,
                    fields: {
                      'source': 'realtime',
                      'row_present': true,
                      'delivered_seq': r.deliveredSeq,
                      'read_seq': r.readSeq,
                      'prev_delivered_seq': prev?.deliveredSeq,
                      'prev_read_seq': prev?.readSeq,
                    },);
                _applyPartnerReceipt(r);
              },
            )
            // Same silent join as the mood channel, and worse: this is the only
            // live path by which the sender's tick ever advances.
            .subscribe((status, err) {
          Diag.record(DiagArea.receipt, 'rt_channel_join', corr: id, fields: {
            'topic_kind': 'receipts',
            'status': status.name,
            'error_class': err?.runtimeType.toString(),
            'partner_id_known': true,
            'attempt_n': attempt,
          },);
        });
      } else {
        // No partner id means no receipts channel is created at all, so the
        // tick has no live source and nothing distinguishes that from a join
        // that failed.
        Diag.record(DiagArea.receipt, 'rt_channel_join', corr: id, fields: {
          'topic_kind': 'receipts',
          'status': 'not_subscribed',
          'partner_id_known': false,
          'attempt_n': attempt,
        },);
      }

      // Rejoining a channel does not replay what it missed while gone.
      await _catchUp(trigger: trigger);
      await _refreshPartnerReceipt(source: trigger);
    } finally {
      _subscribing = false;
    }
  }

  void _onScroll() {
    if (_hasNewMessage && _isAtBottom()) {
      setState(() => _hasNewMessage = false);
    }
  }

  Future<void> _init() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _coupleId = couple.id;
    // Derive the couple key here, where nothing has ever derived it. It is not
    // awaited and its answer is not read: chat works without a key today and
    // must keep working without one on every build already in the field. This
    // only makes the key PRESENT for the encryption that follows, and heals a
    // couple that paired before pairing published keys.
    // prime, not ensure: session_provider already started this when the partner
    // became known, and this joins that future instead of running a second
    // publish + fetch + derive. Still unawaited — the send and read paths await
    // it themselves, so nothing here needs to hold up the first frame.
    unawaited(CoupleKey.prime(ref.read(sessionProvider)));
    // Opening the chat IS reading it. Both halves together, or the shade keeps
    // an entry the owner has already dealt with and the next message counts up
    // from a number nothing on screen agrees with.
    unawaited(UnreadTally.clear(couple.id));
    unawaited(FcmService.clearMessageNotification(couple.id));
    // Before anything is awaited, so the first frame of a re-entered chat draws
    // the ticks it was already showing when the user left it. The disk copy
    // (one frame later, or a whole process later) goes through the same upward
    // clamp, so it can only ever confirm or raise what is on screen.
    final key = _receiptKey;
    if (key != null) {
      _partnerReceipt = _ReceiptMemory.peek(key);
      unawaited(_ReceiptMemory.load(key).then((r) {
        if (r != null) _applyPartnerReceipt(r);
      }),);
    }
    _clearedBefore = await _loadClearedBefore(couple.id);
    try {
      // warm: false — signing is a round trip per bucket and nothing below
      // paints a bubble. The spinner used to cover the fetch AND the signing
      // AND the subscribe AND two receipt refreshes, so the conversation was
      // withheld until every one of them had returned.
      final msgs = await ChatRepository.fetch(couple.id, warm: false);
      _messages.addAll(msgs);
      _sortMessages();
      _ids.addAll(msgs.map((m) => m.id));
    } catch (_) {
      // first-run is fine
    }
    // Paint here. Everything after this point is network work the list does not
    // need in order to show text, and text is most of a conversation.
    if (mounted) setState(() => _loading = false);
    unawaited(ChatRepository.warmMedia(List.of(_messages)).then((_) {
      if (mounted) setState(() {});
    }));
    unawaited(_loadReactions(couple.id));
    // single, idempotent channel-subscribe path
    await _subscribe(trigger: 'chat_open');
    // Photos taken from the shell's camera tab were already uploading before
    // this screen existed — show them now rather than when they land.
    _adoptPending();
    unawaited(PresenceService.setOnline(couple.id, online: true));
    unawaited(PresenceService.setTypingInChat(couple.id, inChat: true));
    // The durable read watermark, written on the two transitions that define it
    // — arriving and leaving. It used to be re-written every five seconds for
    // the whole time a chat was open: two upserts per user per 5s, each one
    // fanned out to the partner through postgres_changes, for a column no
    // screen in the app reads. The heartbeat that keeps a partner reading as
    // online is main.dart's 30s app_last_active_at beat, and always was.
    unawaited(PresenceService.setChatLastRead(couple.id));
    await _refreshPartnerReceipt(source: 'chat_open');
    _ackRead('chat_open', flush: true);
    _tickTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      // A tick, not a rebuild. isTrulyOnline is freshness-gated, so a receipt
      // really can decay with nothing else changing — but a bare setState here
      // rebuilt the entire screen every 5 seconds: the full-screen background
      // image, the app bar, the input bar, and a re-filter of up to 300
      // messages, all to repaint a few 10px ticks. Only the ticks listen now.
      _receiptTick.value++;
    });
    // reverse:true already pins the view to the newest message — no scroll needed.
  }

  /// Sign what a live message needs before its bubble asks for it.
  ///
  /// fetch() and fetchSince() warm a whole page in one round trip, but a
  /// message arriving over realtime or the broadcast fast path has been
  /// through neither: nothing is cached for its path, so voiceUrl/imageUrl
  /// answer null and the bubble renders the "unavailable" placeholder. It sat
  /// there until something re-fetched the page — a resume, or the chat being
  /// reopened. That is the voice note that "shows unavailable for a while
  /// before delivering", and it hit the SENDER too, who has no local file for
  /// a recording the way they do for a photo.
  Future<void> _warmMedia(Message m) async {
    if (m.mediaPaths.isEmpty && m.privatePaths.isEmpty) return;
    await ChatRepository.warmMedia([m]);
    if (mounted) setState(() {});
  }

  void _onIncoming(Message m, {bool fromDb = false, String source = 'local'}) {
    if (kRtChatDebug) {
      debugPrint('[rt] incoming id=${m.id} fromDb=$fromDb kind=${m.kind}');
    }
    unawaited(_warmMedia(m));
    final isDuplicate = _ids.contains(m.id);
    // Recorded at every exit, because the exit taken is the answer: a message
    // that arrives by broadcast alone carries seq 0 (the Message default) and
    // can never be acked, and only the pairing of msg_received{seq:0} with the
    // absence of a later msg_seq_bound for the same id shows that.
    void trace() =>
        Diag.record(DiagArea.receipt, 'msg_received', corr: m.id, fields: {
          'seq': m.seq,
          'from_db': fromDb,
          'source': source,
          'is_mine': m.isMine(SupabaseService.currentUserId),
          'is_duplicate': isDuplicate,
          'chat_mounted': mounted,
          'max_seq_after': _maxSeq,
        },);
    if (isDuplicate) {
      // Already shown (optimistic / broadcast). When the authoritative DB row
      // arrives, adopt its SERVER timestamp + paths so ordering is correct
      // across devices and the status flips to sent.
      if (fromDb && mounted) {
        final i = _messages.indexWhere((x) => x.id == m.id);
        if (i >= 0) {
          final wasOptimistic = _messages[i].seq <= 0;
          setState(() {
            _messages[i] = _messages[i].reconcileWith(m);
            _sortMessages();
          });
          Diag.record(DiagArea.receipt, 'msg_seq_bound', corr: m.id, fields: {
            'seq': m.seq,
            'source': source,
            'was_optimistic': wasOptimistic,
          },);
          // Their message came over broadcast carrying seq 0, so its arrival
          // acked nothing. This is the first moment it has a watermark to send.
          if (wasOptimistic && !m.isMine(SupabaseService.currentUserId)) {
            _ackRead('seq_bound');
          }
        }
      }
      trace();
      return;
    }
    _ids.add(m.id);
    if (!mounted) {
      trace();
      return;
    }
    final mine = m.isMine(SupabaseService.currentUserId);
    final atBottom = _isAtBottom();
    setState(() {
      _messages.insert(0, m); // newest-first ordering
      _sortMessages();
    });
    // I'm looking at the chat, so their message is read the moment it lands.
    // Edge-triggered, where the old 5s timer re-acked a seq that had not moved
    // twelve times a minute.
    if (!mine) {
      _ackRead('incoming');
      // A NEW message from them, LIVE — only the broadcast path cues. The
      // duplicate branch above keeps a broadcast+db echo pair to one sound,
      // and gating on source keeps a reconnect catch-up of N missed messages
      // from playing N chimes in a row.
      if (source == 'broadcast') MilesSound.cue(Cue.receive);
    }
    // Don't yank a user who's reading history; show a chip instead.
    if (mine || atBottom) {
      _scrollToNewest();
    } else {
      setState(() => _hasNewMessage = true);
    }
    trace();
  }

  Future<void> _videoCall() async {
    // In-app WebRTC call. The shell listens for the state change and pushes the
    // call screen; the partner's app rings if it's open.
    await ref.read(callControllerProvider).startCall();
  }

  Future<void> _voiceCall() async {
    await ref.read(callControllerProvider).startCall(video: false);
  }

  void _sortMessages() {
    // Newest first; id as a stable tiebreaker for same-second messages.
    _messages.sort((a, b) {
      final c = b.createdAt.compareTo(a.createdAt);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
  }

  /// With reverse:true the newest message sits at offset 0 (the visual bottom).
  bool _isAtBottom() {
    if (!_scroll.hasClients) return true;
    return _scroll.offset <= _scroll.position.minScrollExtent + 120;
  }

  void _scrollToNewest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target =
          _scroll.position.minScrollExtent; // 0 = newest (reverse:true)
      if (animate) {
        _scroll.animateTo(target,
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut,);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  bool _partnerTyping = false;
  Timer? _partnerTypingTimer;

  void _onTyping(String _) {
    final id = _coupleId;
    if (id == null) return;
    if (!_typingActive) {
      _typingActive = true;
      PresenceService.setTyping(id, typing: true);
      // Instant fast-path (no DB round-trip): dots appear on the partner in ~ms.
      _moodChannel
          ?.sendBroadcastMessage(event: 'typing', payload: {'typing': true});
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 1500), () {
      _typingActive = false;
      PresenceService.setTyping(id, typing: false);
      _moodChannel
          ?.sendBroadcastMessage(event: 'typing', payload: {'typing': false});
    });
  }

  void _onTypingBroadcast(Map<String, dynamic> payload) {
    if (!mounted) return;
    final typing = payload['typing'] == true;
    setState(() => _partnerTyping = typing);
    _partnerTypingTimer?.cancel();
    if (typing) {
      _partnerTypingTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _partnerTyping = false);
      });
    }
  }

  Future<void> _setMyMood() async {
    final id = _coupleId;
    if (id == null) return;
    // Same gate Closer uses: modest mode on means the intimate moods are not
    // offered at all, rather than offered and then regretted.
    final couple = ref.read(sessionProvider).couple;
    final m = await showMoodSelector(
      context,
      intimateAllowed: couple != null && !couple.modestMode,
    );
    if (m == null) return;
    await PresenceService.setMood(id, m.key, m.hex);
  }

  Future<void> _reload() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    try {
      final msgs = await ChatRepository.fetch(couple.id);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(msgs);
        _sortMessages();
        _ids
          ..clear()
          ..addAll(msgs.map((m) => m.id));
        // Messages can vanish under an open selection — the partner deletes
        // one for everyone while it is picked. A stale id would inflate the
        // count and make _allSelectedAreMine vacuously true.
        _selection.prune(_ids);
        // Rows that are gone stop paying for a measured height; without this
        // the map is a leak the length of the conversation.
        _rowOffsets.forgetAllExcept(_ids);
      });
    } catch (_) {}
  }

  _MsgStatus _statusFor(Message m, Presence? p) {
    final st = _rawStatusFor(m);
    // Only when it moves. This runs for every bubble on every 5s tick, and the
    // one transition that matters would be lost in the restatement of 300 that
    // did not change.
    if (_tracedTick[m.id] != st) {
      _tracedTick[m.id] = st;
      Diag.record(DiagArea.receipt, 'tick_rendered', corr: m.id, fields: {
        'msg_seq': m.seq,
        'partner_delivered_seq': _partnerReceipt?.deliveredSeq,
        'partner_read_seq': _partnerReceipt?.readSeq,
        'status': st.name,
      },);
    }
    return st;
  }

  /// The rung to draw. Only ever rises for a given message, by construction:
  /// `seq` is fixed once bound, and `_partnerReceipt` is clamped upward by
  /// [_applyPartnerReceipt] and survives a remount via [_ReceiptMemory].
  _MsgStatus _rawStatusFor(Message m) {
    // A bound seq means the row IS on the server — that is where seq comes
    // from. So the queue's opinion is stale from that moment on, and reading it
    // first let a delivered message fall back to the clock (or to "didn't
    // send") if a retry re-marked an entry the echo had already reconciled.
    // Below it, the send states its own fate: seq alone could not, being 0
    // both for a message still on the wire and for one whose insert threw, so
    // a message that never reached the server drew the delivered tick.
    if (m.seq <= 0) {
      switch (m.sendStatus) {
        case SendStatus.sending:
          return _MsgStatus.sending;
        case SendStatus.failed:
          return _MsgStatus.failed;
        case SendStatus.sent:
          // On the server, but this device has not been told its seq yet.
          return _MsgStatus.sent;
      }
    }
    final r = _partnerReceipt;
    if (r == null) return _MsgStatus.sent;
    if (r.readSeq >= m.seq) return _MsgStatus.seen;
    // DELIVERED is now a real fact the partner's device acked, not a
    // restatement of "their app is in the foreground".
    if (r.deliveredSeq >= m.seq) return _MsgStatus.delivered;
    return _MsgStatus.sent;
  }


  /// What there is to copy off a message, empty when there is nothing.
  ///
  /// Only the body. previewText() would happily hand back '📷 Photo' for a
  /// picture, and pasting that into another app is worse than the copy button
  /// not being there.
  static String _copyableText(Message m) => (m.body ?? '').trim();

  Future<void> _copyMessage(Message m) async {
    final text = _copyableText(m);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied'),
        backgroundColor: MilesColors.sage,
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Saves an image or video message to the private vault, with brief feedback.
  Future<void> _saveMessageMedia(Message m) async {
    final uid = SupabaseService.currentUserId;
    final partnerName =
        ref.read(sessionProvider).partner?.displayName ?? 'your partner';
    final sender = m.isMine(uid) ? 'you' : partnerName;
    var success = false;
    if (m.kind == 'image') {
      final url = m.imageUrl;
      if (url != null) {
        success =
            await SaveMediaService.savePhotoToVault(url: url, senderName: sender);
      }
    } else if (m.kind == 'video' && m.videoPath != null) {
      success = await SaveMediaService.saveVideoToVault(
          path: m.videoPath!, senderName: sender,);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            success ? 'Saved to your vault 🔒' : 'Could not save to vault',),
        backgroundColor: success ? MilesColors.sage : MilesColors.ember,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Called by the realtime DELETE callback when the partner clears the chat.
  /// Debounced: a bulk delete fires one event per message; we reload once.
  void _onRemoteDelete() {
    if (_reloadScheduled) return;
    _reloadScheduled = true;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _reload();
        setState(() => _reloadScheduled = false);
      }
    });
  }

  /// Partner cleared the whole conversation — instant signal over the broadcast
  /// channel (the reliable path; postgres DELETE realtime is the backstop). The
  /// rows are already gone server-side, so just empty the screen locally.
  void _onClearedBroadcast(Map<String, dynamic> payload) {
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _ids.clear();
      // Nothing left to act on; a surviving selection bar would be a count of
      // messages that no longer exist.
      _selection.clear();
    });
  }

  void _toggleSelected(String id) {
    final m = _messages.where((m) => m.id == id).firstOrNull;
    if (m == null) return;
    setState(() => _selection.toggle(m));
  }

  /// Selecting an album selects everything in it.
  ///
  /// An album is one bubble but many rows, and a delete that took only the one
  /// the tap resolved to would leave the other nineteen photos of a send behind
  /// as a smaller grid — which reads as the delete having failed.
  void _toggleSelectedRow(ChatRow row) {
    if (!row.isAlbum) return _toggleSelected(row.newest.id);
    final on = _selection.contains(row.newest.id);
    setState(() {
      for (final m in row.items) {
        if (_selection.contains(m.id) == on) _selection.toggle(m);
      }
    });
  }

  void _clearSelection() => setState(_selection.clear);

  /// The bar a long press opens. [anchor] is the row's rectangle on screen,
  /// measured at the press so it survives a list that is still settling.
  Future<void> _openReactionBar(ChatRow row, Rect anchor,
      {required bool mine,}) async {
    final m = row.newest;
    // The same predicate the selection uses: a message still uploading has no
    // row for the reaction's foreign key to point at, and one already deleted
    // for everyone has nothing left to react to.
    if (!ChatSelection.canSelect(m)) return;
    if (_blockedByEdit()) return;
    final uid = SupabaseService.currentUserId;
    var choice = await ReactionBar.show(
      context,
      anchor: anchor,
      mine: mine,
      current: _reactions.emojiOf(m.id, uid ?? ''),
    );
    if (!mounted) return;
    if (choice == kReactionMore) {
      choice = await showReactionPicker(context);
      if (!mounted) return;
    }
    // A dismiss LEAVES the selection the long press made. It is the only way
    // into selection mode, and the bar's own barrier swallows the tap that
    // would add a second message — so cancelling here made bulk delete
    // unreachable: every long press ended with the selection gone. The close
    // button and back are still the way out.
    if (choice == null) return;
    // Checked AGAIN, not only before the bar opened. The partner can delete
    // the message for everyone while the bar — or the picker behind it — is
    // up, and the row captured in this closure would not know: the reaction
    // would seal, broadcast and land durably on a message whose body has just
    // been scrubbed, where neither screen can show it to be taken back.
    final live = _byId(m.id);
    if (live == null || !ChatSelection.canSelect(live)) return;
    // Choosing an emoji does consume the gesture — but only the selection that
    // gesture created, never one the user has since built on top of it.
    // Compared against the SELECTABLE items: an album whose middle photo is
    // still uploading selects fewer rows than it holds, and against
    // row.items.length that equality could never be true.
    final selectable = row.items.where(ChatSelection.canSelect).toList();
    final onlyThisRow = selectable.isNotEmpty &&
        _selection.length == selectable.length &&
        selectable.every((i) => _selection.contains(i.id));
    if (onlyThisRow) _clearSelection();
    await _react(m, choice);
  }

  /// Apply [emoji] to [m], or take it back when it is already this user's.
  ///
  /// Paints FIRST and talks after: nothing is awaited before the setState, so
  /// the chip is on screen in the same frame as the tap, on any connection.
  Future<void> _react(Message m, String emoji) async {
    final uid = SupabaseService.currentUserId;
    final coupleId = _coupleId;
    if (uid == null || coupleId == null) return;
    final now = DateTime.now();
    final previous = _reactions.emojiOf(m.id, uid);
    final next = _reactions.tap(m.id, uid, emoji);
    // Painted here, synchronously, before a single await below. On a dead
    // connection this is still the whole of what the user sees happen.
    if (_reactions.apply(m.id, uid, next, now)) setState(() {});
    unawaited(HapticFeedback.selectionClick());

    final sealed = next == null
        ? null
        : await ChatReactionRepository.seal(
            emoji: next, messageId: m.id, userId: uid, at: now,);
    if (next != null && sealed == null) {
      // No couple key on this device. The emoji cannot be written anywhere it
      // could later be read, and writing it in the clear is not on the table —
      // so the paint comes back off and the user is told, rather than a
      // reaction sitting on screen that the partner will never see.
      if (!mounted) return;
      if (_reactions.apply(
        m.id,
        uid,
        previous,
        now.add(const Duration(milliseconds: 1)),
      )) {
        setState(() {});
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't send that reaction yet — still setting up "
            'this device.',),
      ),);
      return;
    }
    // The faster of the two wires and the one the partner renders from, sent
    // beside the durable write and never instead of it.
    unawaited(_moodChannel?.sendBroadcastMessage(
      event: 'react',
      payload: ChatReactionRepository.broadcastPayload(
        from: uid,
        messageId: m.id,
        at: now,
        sealed: sealed,
      ),
    ),);
    await ChatReactionOutbox.instance.enqueue(
      coupleId: coupleId,
      messageId: m.id,
      userId: uid,
      sealed: sealed,
      at: now,
    );
  }

  /// A reaction the partner just made, over the broadcast fast path.
  void _onReactionBroadcast(Map<String, dynamic> payload) {
    final r = ChatReactionRepository.fromBroadcast(payload);
    if (r == null || !mounted) return;
    unawaited(
      _reactions
          .applyIncoming(r, myUid: SupabaseService.currentUserId)
          .then((changed) {
        if (changed && mounted) setState(() {});
      }),
    );
  }

  /// The durable half of the same event. Broadcast is at-most-once, so this is
  /// what still moves the screen when one is dropped — no reopen, no refresh.
  void _onReactionRow(PostgresChangePayload payload) {
    final removal = payload.eventType == PostgresChangeEvent.delete;
    final row = removal ? payload.oldRecord : payload.newRecord;
    if (row.isEmpty || !mounted) return;
    final messageId = row['message_id']?.toString();
    final userId = row['user_id']?.toString();
    if (messageId == null || userId == null) return;
    // Our own row is the one thing this device knows better than the server:
    // an unsent change is still in the outbox, and echoing the old value back
    // over it is exactly the flicker this must not have.
    if (userId == SupabaseService.currentUserId) return;
    if (removal) {
      // Under RLS the DELETE payload is the primary key and NOTHING else, so
      // this event cannot be ordered against anything: no updated_at, and the
      // value the row held was written by the ADD anyway. Deriving a timestamp
      // for it killed a re-add that had already arrived over the faster wire.
      // So drop what this device believed and ask the server, which is the
      // only party that knows. The broadcast still makes the ordinary removal
      // instant; this is the backstop for when that broadcast was dropped.
      final coupleId = _coupleId;
      setState(() => _reactions.forget(messageId, userId));
      if (coupleId != null) unawaited(_loadReactions(coupleId));
      return;
    }
    final at = DateTime.tryParse(row['updated_at']?.toString() ?? '')?.toLocal();
    if (at == null) return;
    unawaited(() async {
      final emoji = await ChatReactionRepository.openRow(
        row,
        messageId: messageId,
        userId: userId,
      );
      if (emoji == null || !mounted) return;
      if (_reactions.apply(messageId, userId, emoji, at)) setState(() {});
    }(),);
  }

  /// Everything already on the conversation, once the messages are on screen.
  ///
  /// Deliberately after the paint and never awaited by it: a reaction is worth
  /// nothing if the price is the conversation arriving later.
  Future<void> _loadReactions(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    // Single-flight. A resume produces TWO triggers — this screen's own
    // lifecycle callback and the shell's forced socket reconnect — and a
    // durable DELETE asks for one as well; without this, every resume ran two
    // full request fan-outs and two decrypt passes over the whole
    // conversation, and each was an independent chance to snapshot the server
    // mid-write.
    if (_reactionFetchBusy) {
      _reactionFetchAgain = true;
      return;
    }
    _reactionFetchBusy = true;
    try {
      // Per-account, and this is also what restores whatever a process kill
      // left unsent.
      await ChatReactionOutbox.instance.bindUser(uid);
      do {
        _reactionFetchAgain = false;
        if (!mounted) return;
        try {
          // Read BEFORE the fetch: both live wires are already delivering, and
          // on a cold open the decrypt inside fetchFor waits on the couple-key
          // derive.
          final asOfWrites = _reactions.writes;
          final fetched = await ChatReactionRepository.fetchFor(
            coupleId,
            _messages.map((m) => m.id),
          );
          if (!mounted) return;
          setState(() {
            _reactions.mergeFetched(fetched, asOfWrites: asOfWrites);
            _applyPendingReactions();
          });
        } catch (e) {
          // Counted, never silent: reactions that never arrive look exactly
          // like a conversation nobody reacted to.
          Diag.record(DiagArea.receipt, 'reaction_fetch_failed', corr: coupleId,
              fields: {'error_class': e.runtimeType.toString()},);
          debugPrint('[reactions] fetch failed: ${e.runtimeType}');
          return;
        }
      } while (_reactionFetchAgain);
    } finally {
      _reactionFetchBusy = false;
    }
  }

  /// What this device has decided but not yet landed outranks the page it just
  /// fetched — otherwise a reaction made offline is painted and then quietly
  /// erased by the server's older answer.
  void _applyPendingReactions() {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    for (final intent in ChatReactionOutbox.instance.pending.values) {
      if (intent.userId != uid) continue;
      final emoji = intent.isRemoval ? null : intent.emoji;
      // A restored intent whose emoji would not decrypt: the write still
      // carries the right ciphertext, but this device cannot paint it.
      if (!intent.isRemoval && emoji == null) continue;
      _reactions.apply(intent.messageId, uid, emoji, intent.at);
    }
  }

  /// Reactions the server refused for good.
  void _onReactionOutbox() {
    final refused = ChatReactionOutbox.instance.takeRefusals();
    if (refused.isEmpty || !mounted) return;
    final uid = SupabaseService.currentUserId;
    final coupleId = _coupleId;
    if (uid != null) {
      for (final intent in refused) {
        // Not "roll back to nothing" — that is only right when the refused
        // write was the FIRST reaction on this message. Refuse a change of
        // mind and the server still holds the previous emoji, which the
        // partner can still see. This device's opinion is simply void now, so
        // it forgets the key (its ordering included) and re-reads.
        _reactions.forget(intent.messageId, uid);
      }
      if (coupleId != null) unawaited(_loadReactions(coupleId));
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(refused.length == 1
          ? 'A reaction could not be saved.'
          : '${refused.length} reactions could not be saved.',),
    ),);
  }

  /// Open the pager on [tapped], inside every photo and video the conversation
  /// has — not just the one that was touched.
  ///
  /// The set is built here rather than in the bubble because this holds the
  /// loaded conversation, and [ChatMediaSource] can page back past it.
  void _openMedia(Message tapped, String partnerName) {
    final coupleId = _coupleId;
    if (coupleId == null) return;
    final uid = SupabaseService.currentUserId;
    final media = _messages
        .where((m) =>
            (m.kind == 'image' || m.kind == 'video') &&
            !m.deletedForEveryone &&
            !m.isHiddenFor(uid),)
        .toList();
    if (media.isEmpty) return;
    final source = ChatMediaSource(
      coupleId: coupleId,
      seed: media,
      senderNameFor: (m) => m.isMine(uid) ? 'you' : partnerName,
    );
    MediaViewer.open(context, source, index: source.indexOf(tapped));
  }

  /// Reply and Save act on a single message, so they only appear when exactly
  /// one is picked.
  Message? get _onlySelected =>
      _selection.length == 1 ? _selection.resolve(_messages).firstOrNull : null;

  /// Delete everything selected, in one action.
  ///
  /// Deleting one message at a time through the long-press sheet was the only
  /// way to remove anything, which for a handful of photos is a lot of taps for
  /// something the user has already decided.
  Future<void> _deleteSelected({required bool everyone}) async {
    // deleteAll marks itself busy synchronously, so start it first and then
    // rebuild: the delete button reads busy and goes quiet for the duration
    // rather than queueing a second pass over the same messages.
    final pending = _selection.deleteAll(everyone
        ? ChatRepository.deleteForEveryone
        : ChatRepository.deleteForMe,);
    setState(() {});
    final failed = await pending;
    if (!mounted) return;
    setState(() {});
    await _reload();
    if (failed.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed.length == 1
            ? '1 message could not be deleted — still selected.'
            : '${failed.length} messages could not be deleted — still '
                'selected.',),
      ),);
    }
  }

  /// The sweep button. With a selection it deletes exactly what is selected;
  /// with nothing selected it still clears the whole conversation, which is
  /// what it has always done.
  Future<void> _clearOrDeleteSelected() async {
    if (_selecting) {
      await _confirmDeleteSelected();
      return;
    }
    await _clearConversation();
  }

  Future<void> _confirmDeleteSelected() async {
    final n = _selection.length;
    final mineOnly =
        _selection.allMine(_messages, SupabaseService.currentUserId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                n == 1 ? 'Delete this message?' : 'Delete $n messages?',
                style: const TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.visibility_off, color: MilesColors.taupe),
              title: const Text('Delete for me',
                  style: TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (mineOnly)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Color(0xFFB83A57)),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: Color(0xFFB83A57)),),
                onTap: () => Navigator.pop(ctx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.close, color: MilesColors.faint),
              title: const Text('Cancel',
                  style: TextStyle(color: MilesColors.taupe),),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await _deleteSelected(everyone: choice == 'everyone');
  }

  Future<void> _clearConversation() async {
    final session = ref.read(sessionProvider);
    final partnerName = session.partner?.displayName ?? 'your partner';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: Text(
          'This will permanently delete all messages for both you and '
          '$partnerName. This cannot be undone.',
          style: const TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: MilesColors.ember,),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete for everyone'),),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ChatRepository.clearConversation();
      // Instant fan-out to the partner over the live broadcast channel (same
      // reliable path as typing/msg). Postgres DELETE realtime is the backstop.
      // NOT `const {}`. realtime_client writes into the payload map it is
      // handed, so a const literal threw UnsupportedError out of
      // _UnmodifiableMapMixin.[]= and the partner was never told — every clear
      // was one-sided until the Postgres DELETE backstop caught up. Seen on a
      // real handset on build 40; every other broadcast here already passes a
      // mutable literal, and this is the only one whose payload is empty.
      unawaited(
        _moodChannel?.sendBroadcastMessage(event: 'cleared', payload: {}),
      );
      if (mounted) {
        setState(() {
          _messages.clear();
          // Nothing survives the clear, so nothing can still be selected.
          _selection.clear();
          _ids.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not clear the conversation.')),);
      }
    }
  }

  String _clearedKey(String coupleId) =>
      'chat_cleared_${coupleId}_${SupabaseService.currentUserId ?? ''}';

  Future<DateTime?> _loadClearedBefore(String coupleId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_clearedKey(coupleId));
      return s == null ? null : DateTime.tryParse(s);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    realtimeResumed.removeListener(_subscribe);
    _receiptTick.dispose();
    final rc = _receiptChannel;
    if (rc != null) SupabaseService.client.removeChannel(rc);
    ChatSendQueue.instance.removeListener(_adoptPending);
    ChatReactionOutbox.instance.removeListener(_onReactionOutbox);
    final xc = _reactionChannel;
    if (xc != null) SupabaseService.client.removeChannel(xc);
    _typingTimer?.cancel();
    _partnerTypingTimer?.cancel();
    _highlightTimer?.cancel();
    _tickTimer?.cancel();
    _flushReadAck('chat_close');
    final id = _coupleId;
    if (id != null) {
      PresenceService.setTyping(id, typing: false);
      PresenceService.setTypingInChat(id, inChat: false);
      PresenceService.setChatLastRead(id);
    }
    final client = SupabaseService.client;
    final c1 = _channel;
    final c2 = _moodChannel;
    if (ChatBroadcastService.active == c2) ChatBroadcastService.active = null;
    if (c1 != null) client.removeChannel(c1);
    if (c2 != null) client.removeChannel(c2);
    _scroll.dispose();
    _audioRecorder.dispose();
    _voice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final partnerName = session.partner?.displayName;
    final uid = SupabaseService.currentUserId;
    final presence = ref.watch(partnerPresenceProvider);
    final partnerMood = moodByKey(presence?.currentMood);
    final themeCtrl = ref.watch(chatThemeProvider);
    final chatTheme = themeCtrl.theme;
    final chatBgPath = themeCtrl.bgPath;
    final one = _onlySelected;

    return PopScope(
      // Back gets you out of the selection first. Leaving the chat instead
      // would make an accidental long-press feel like a trap.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // The drawer belongs to the shell's Scaffold and parks its own history
        // entry on this route. Refusing the pop jumps that queue, so put the
        // drawer back where it was rather than silently eating the press.
        final shell = rootScaffoldKey.currentState;
        if (shell != null && shell.isDrawerOpen) {
          shell.closeDrawer();
          return;
        }
        _clearSelection();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
            ),
          ),
          title: GestureDetector(
            // The whole title block, not just the letters: the name and the
            // presence line under it are one target, the way they are in every
            // other messenger.
            onTap: partnerName == null
                ? null
                : () => context.push('/app/partner'),
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(partnerName ?? 'Chat',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: MilesColors.cream50,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,),),
                    ),
                    if (partnerMood != null) ...[
                      const SizedBox(width: 8),
                      AnimatedMood(mood: partnerMood, size: 20),
                    ],
                  ],
                ),
                if (partnerName != null)
                  _ChatSubtitle(
                      presence: presence, partnerTyping: _partnerTyping,),
              ],
            ),
          ),
          actions: [
            // Presence sits beside their name, where it means something, instead
            // of floating over the middle of the conversation.
            const PartnerHereAction(),
            if (couple != null)
              IconButton(
                tooltip: 'Voice call',
                icon: const Icon(Icons.call_outlined, color: MilesColors.ember),
                onPressed: _voiceCall,
              ),
            if (couple != null)
              IconButton(
                tooltip: 'Video call',
                icon:
                    const Icon(Icons.videocam_outlined, color: MilesColors.ember),
                onPressed: _videoCall,
              ),
            if (couple != null)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: MilesColors.gilt),
                color: MilesColors.surface1,
                onSelected: (v) {
                  switch (v) {
                    case 'mood':
                      _setMyMood();
                    case 'gif':
                      _pickGifBurst();
                    case 'theme':
                      showChatThemePicker(context);
                    case 'clear':
                      _clearConversation();
                    case 'report':
                      // No ref: this is the conversation, not one message. The
                      // per-message route is the selection toolbar below.
                      showReportSheet(context, target: ReportTarget.partner);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'mood', child: Text('Set your mood')),
                  PopupMenuItem(value: 'gif', child: Text('Fling a GIF 🎞️')),
                  PopupMenuItem(value: 'theme', child: Text('Chat theme')),
                  PopupMenuItem(
                      value: 'clear', child: Text('Clear conversation'),),
                  PopupMenuItem(
                      value: 'report', child: Text('Report a problem'),),
                ],
              ),
          ],
        ),
        body: couple == null
            ? const _NotLinked()
            : Stack(
                children: [
                  Positioned.fill(
                      child: _ChatBg(theme: chatTheme, bgPath: chatBgPath),),
                  Column(
                    children: [
                      // Only while selecting. It says how many, and — more
                      // importantly — gives an obvious way out, so entering
                      // selection by accident is not a trap.
                      if (_selecting)
                        Material(
                          color: MilesColors.surface2,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 6,),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.close,
                                        color: MilesColors.cream50,),
                                    onPressed: _clearSelection,
                                  ),
                                  Text(
                                    '${_selection.length} selected',
                                    style: const TextStyle(
                                        color: MilesColors.cream50,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,),
                                  ),
                                  const Spacer(),
                                  if (one != null) ...[
                                    if (_copyableText(one).isNotEmpty)
                                      IconButton(
                                        tooltip: 'Copy text',
                                        icon: const Icon(Icons.copy_rounded,
                                            color: MilesColors.cream50,),
                                        onPressed: () {
                                          _clearSelection();
                                          _copyMessage(one);
                                        },
                                      ),
                                    // Offered only where the server would
                                    // accept it: your own text, still within
                                    // the window. The server decides regardless
                                    // — this only avoids a button that is
                                    // already doomed.
                                    if (_canEdit(one, uid))
                                      IconButton(
                                        tooltip: 'Edit',
                                        icon: const Icon(Icons.edit_outlined,
                                            color: MilesColors.gilt,),
                                        onPressed: () {
                                          _clearSelection();
                                          _startEdit(one);
                                        },
                                      ),
                                    IconButton(
                                      tooltip: 'Reply',
                                      icon: const Icon(Icons.reply,
                                          color: MilesColors.emberSoft,),
                                      onPressed: () {
                                        _clearSelection();
                                        _startReply(one);
                                      },
                                    ),
                                    if (one.kind == 'image' ||
                                        one.kind == 'video')
                                      IconButton(
                                        tooltip: 'Save to gallery',
                                        icon: const Icon(Icons.download_rounded,
                                            color: MilesColors.cream50,),
                                        onPressed: () {
                                          _clearSelection();
                                          _saveMessageMedia(one);
                                        },
                                      ),
                                    IconButton(
                                      tooltip: 'Report',
                                      icon: const Icon(Icons.flag_outlined,
                                          color: MilesColors.cream50,),
                                      onPressed: () {
                                        _clearSelection();
                                        showReportSheet(context,
                                            target: ReportTarget.message,
                                            targetRef: one.id,);
                                      },
                                    ),
                                  ],
                                  IconButton(
                                    tooltip: 'Delete selected',
                                    icon: const Icon(Icons.delete_outline,
                                        color: Color(0xFFB83A57),),
                                    // Quiet while a batch is running: the
                                    // deletes are sequential and a second tap
                                    // would sit behind all of them.
                                    onPressed: _selection.busy
                                        ? null
                                        : _confirmDeleteSelected,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: _loading
                            ? const Center(child: CircularProgressIndicator())
                            : _messages.isEmpty
                                ? const _EmptyChat()
                                : Builder(builder: (_) {
                                    // Media sent together collapses into one
                                    // row here, so the list builds grids rather
                                    // than one full-width bubble per photo.
                                    final rows = _visibleRows(uid);
                                    if (rows.isEmpty) {
                                      return const _EmptyChat();
                                    }
                                    return Stack(
                                      children: [
                                        Listener(
                                          // A jump in flight always loses to
                                          // the user's own thumb. Without this
                                          // the search keeps jumping the list
                                          // out from under a finger that is
                                          // already scrolling it.
                                          onPointerDown: (_) =>
                                              _jumpGeneration++,
                                          child: ListView.builder(
                                          controller: _scroll,
                                          reverse: true,
                                          padding: const EdgeInsets.fromLTRB(
                                              16, 12, 16, 12,),
                                          itemCount: rows.length,
                                          itemBuilder: (_, i) {
                                            final row = rows[i];
                                            final m = row.newest;
                                            // Descending list: the older neighbour is
                                            // i+1, so a date header marks the oldest
                                            // message of each day (top of the group).
                                            // Compared against this row's OLDEST,
                                            // since an album can straddle midnight.
                                            final showTime =
                                                i == rows.length - 1 ||
                                                    !DateUtils.isSameDay(
                                                        rows[i + 1]
                                                            .newest
                                                            .createdAt,
                                                        row.oldest.createdAt,);
                                            // Rebuilt only when a finger lands
                                            // on or leaves a waveform, which is
                                            // twice per scrub and only for the
                                            // rows on screen.
                                            return MeasuredRow(
                                              // Layout is the only honest
                                              // source for a row height: a
                                              // bubble is one line or ten, a
                                              // photo grid or a voice note.
                                              onHeight: (h) => _rowOffsets
                                                  .record(m.id, h),
                                              child: KeyedSubtree(
                                              // Only the row being walked to
                                              // wears the key, so 299 others do
                                              // not mint a GlobalKey each.
                                              key: _revealId == m.id
                                                  ? _revealKey
                                                  : null,
                                              child: ValueListenableBuilder<
                                                String?>(
                                              valueListenable: _voice.scrubbing,
                                              builder: (context, scrubbing, _) =>
                                                  Dismissible(
                                                key: ValueKey('rpl-${m.id}'),
                                                // Stood down while this note is
                                                // being scrubbed. Both this and
                                                // the waveform want horizontal
                                                // drags, and leaving both live
                                                // lets the gesture arena decide
                                                // on pointer-event ordering —
                                                // which goes the wrong way on a
                                                // flick, sliding the message
                                                // into a reply mid-scrub.
                                                direction: scrubbing == m.id
                                                    ? DismissDirection.none
                                                    : DismissDirection
                                                        .startToEnd,
                                                dismissThresholds: const {
                                                  DismissDirection.startToEnd:
                                                      0.22,
                                                },
                                                confirmDismiss: (_) async {
                                                  _startReply(m); // slide → reply
                                                  return false; // snap back
                                                },
                                                background: const Padding(
                                                  padding:
                                                      EdgeInsets.only(left: 28),
                                                  child: Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: Icon(Icons.reply,
                                                        color: MilesColors.blush,),
                                                  ),
                                                ),
                                                child: SelectableMessage(
                                                  selecting: _selecting,
                                                  selected:
                                                      _selection.contains(m.id),
                                                  onToggle: () =>
                                                      _toggleSelectedRow(row),
                                                  onLongPressAt: (anchor) =>
                                                      _openReactionBar(row,
                                                          anchor,
                                                          mine: m.isMine(uid),),
                                                  child: _Bubble(
                                                    message: m,
                                                    reactions: _reactions
                                                        .forMessage(m.id),
                                                    myUid: uid,
                                                    onReact: (emoji) =>
                                                        _react(m, emoji),
                                                    album:
                                                        row.isAlbum ? row : null,
                                                    onOpenMedia: (t) =>
                                                        _openMedia(
                                                            t,
                                                            partnerName ??
                                                                'your partner',),
                                                    mine: m.isMine(uid),
                                                    showDateHeader: showTime,
                                                    repliedTo: _byId(m.replyToId),
                                                    replyAuthor:
                                                        _replyAuthorFor(
                                                            m, uid,
                                                            partnerName,),
                                                    onTapReply: m.replyToId ==
                                                            null
                                                        ? null
                                                        : () => unawaited(
                                                            _jumpToMessage(
                                                                m.replyToId!,
                                                                uid,),),
                                                    highlighted:
                                                        _highlightedId == m.id,
                                                    voice: _voice,
                                                    theme: chatTheme,
                                                    senderName: m.isMine(uid)
                                                        ? 'you'
                                                        : (partnerName ??
                                                            'your partner'),
                                                    tick: _receiptTick,
                                                    status: m.isMine(uid)
                                                        ? () => _statusFor(
                                                            m, presence,)
                                                        : null,
                                                    onRetry: m.kind == 'text'
                                                        ? () => ChatSendQueue
                                                            .instance
                                                            .retryText(m.id)
                                                        : null,
                                                  ),
                                                ),),
                                            ),),);
                                          },
                                        ),),
                                        if (_hasNewMessage)
                                          Positioned(
                                            bottom: 12,
                                            left: 0,
                                            right: 0,
                                            child: Center(
                                              child: _NewMessageChip(
                                                onTap: () {
                                                  setState(() =>
                                                      _hasNewMessage = false,);
                                                  _scrollToNewest();
                                                },
                                              ),
                                            ),
                                          ),
                                        for (final b in _bursts)
                                          _BurstAnimation(
                                            key: ValueKey(b.id),
                                            mood: b.mood,
                                            gifUrl: b.gifUrl,
                                            onDone: () => _removeBurst(b.id),
                                          ),
                                      ],
                                    );
                                  },),
                      ),
                      // The "<name> is here" strip used to live here. Removed: it
                      // duplicated the global presence avatar, and it read from
                      // `isActivelyInChat` (chat_last_read within 20s) rather than
                      // the live screen, so it kept claiming they were in the chat
                      // for up to 20 seconds after they had walked away. One
                      // signal, one source — see PartnerHereBadge.
                      ChatInputBar(
                        coupleId: couple.id,
                        onChanged: _onTyping,
                        replyingTo: _replyingTo,
                        onCancelReply: _cancelReply,
                        editingMessage: _editingMessage,
                        onCancelEdit: _cancelEdit,
                        onSendText: (t) {
                          final editing = _editingMessage;
                          return editing == null
                              ? _sendTextFast(couple.id, t)
                              : _saveEdit(editing, t);
                        },
                        onSendMedia: (items) =>
                            _sendMediaBatch(couple.id, items),
                        onSendFiles: (docs) =>
                            _sendDocuments(couple.id, docs),
                        onSendVoice: (f, id, peaks) =>
                            _sendVoiceOnce(couple.id, f, id, peaks),
                        onSendVideo: (f) => ChatRepository.sendVideo(couple.id, f,
                            replyToId: _takeReplyId(),),
                        onFlingGif: _flingGifFile,
                        onPickGif: _attachGif,
                        onClearConversation: _clearOrDeleteSelected,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Presence-aware AppBar subtitle: typing… / Online / Last seen.
class _ChatSubtitle extends StatelessWidget {
  const _ChatSubtitle({required this.presence, this.partnerTyping = false});
  final Presence? presence;
  final bool partnerTyping;

  @override
  Widget build(BuildContext context) {
    final p = presence;
    if (p == null) {
      return const Text('together, even from here',
          style: TextStyle(fontSize: 11, color: MilesColors.taupe),);
    }
    // Only show typing if the partner is genuinely online — prevents a stale
    // typing flag (left over after they left) from showing "typing…" forever.
    if ((partnerTyping || (p.isTyping && p.typingInChat)) && p.isTrulyOnline) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('typing',
              style: TextStyle(fontSize: 11, color: MilesColors.sage),),
          SizedBox(width: 6),
          TypingIndicator(),
        ],
      );
    }
    // Use the freshness-gated online check — isOnline alone is the stored bool
    // which never expires on a hard kill.
    if (p.isTrulyOnline) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: MilesColors.sage),
          SizedBox(width: 6),
          Text('Online',
              style: TextStyle(fontSize: 11, color: MilesColors.sage),),
        ],
      );
    }
    // Stale / offline — show last seen via the freshness-derived text.
    final text = p.lastSeenText ?? 'Offline';
    return Text(
      text,
      style: const TextStyle(fontSize: 11, color: MilesColors.taupe),
    );
  }

}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),);
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showDateHeader,
    required this.voice,
    required this.theme,
    required this.senderName,
    required this.tick,
    required this.onOpenMedia,
    required this.onReact,
    this.album,
    this.repliedTo,
    this.replyAuthor,
    this.onTapReply,
    this.highlighted = false,
    this.status,
    this.onRetry,
    this.reactions,
    this.myUid,
  });

  final Message message;
  final bool mine;

  /// userId → that person's reaction to THIS message, or null when nobody has
  /// reacted. Null and empty draw the same nothing; both are ordinary.
  final Map<String, ChatReaction>? reactions;
  final String? myUid;

  /// Tapping a chip toggles this user's own reaction to that emoji — the same
  /// call the bar makes, so there is one way to react and one to take it back.
  final void Function(String emoji) onReact;
  final bool showDateHeader;
  final VoiceNotePlayer voice;
  final ChatTheme theme;
  final String senderName;
  final Message? repliedTo;

  /// The quoted message's author, shown on the quote card.
  final String? replyAuthor;

  /// Walk the conversation to the quoted message.
  final VoidCallback? onTapReply;

  /// Wearing the landing flash after a jump.
  final bool highlighted;

  /// Set when this bubble stands for a whole send rather than one photo. The
  /// grid replaces the single-photo body; everything around it — the reply
  /// quote, the timestamp, the tick — is the bubble's as usual.
  final ChatRow? album;

  /// Opens the pager on a specific message of the conversation's media.
  ///
  /// The bubble does not build the set: it belongs to the screen, which holds
  /// the loaded conversation and can page further back than any one bubble
  /// knows about.
  final void Function(Message) onOpenMedia;

  /// Evaluated lazily on every tick, because a receipt decays with the clock:
  /// isTrulyOnline is freshness-gated, so the same message yields a different
  /// status as time passes with no other state change.
  final _MsgStatus Function()? status;

  /// Send this bubble again after it failed. Null for the kinds that already
  /// offer their own retry on the media itself.
  final VoidCallback? onRetry;

  /// Bumped every 5s. Only the tick listens.
  final ValueListenable<int> tick;

  @override
  Widget build(BuildContext context) {
    final content = _body(context);
    if (!highlighted) return content;
    // Painted BEHIND the row rather than wrapped around it. A translucent fill
    // holding content is the thing repo_hygiene's glass rule bans, and rightly:
    // the bubble is what you read, and it stays opaque. This is a wash on the
    // background, sized to the row and taking no touches.
    //
    // Fades out on its own rather than waiting to be told: the flash is a
    // pointer, and one that stays becomes part of the bubble.
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 1, end: 0),
              duration: const Duration(milliseconds: 1500),
              curve: Curves.easeOut,
              builder: (context, t, _) => DecoratedBox(
                decoration: BoxDecoration(
                  color: MilesColors.gilt.withValues(alpha: 0.18 * t),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }

  Widget _body(BuildContext context) {
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showDateHeader)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                _dayHeaderFormat.format(message.createdAt),
                style: const TextStyle(fontSize: 11, color: MilesColors.faint),
              ),
            ),
          ),
        Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: message.kind == 'text'
                ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
                : const EdgeInsets.all(4),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.74,
            ),
            decoration: BoxDecoration(
              color: mine ? theme.myBubble : theme.partnerBubble,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 4),
                bottomRight: Radius.circular(mine ? 4 : 18),
              ),
              border: mine
                  ? null
                  : Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (repliedTo != null)
                  _ReplyPreview(
                    message: repliedTo!,
                    on: mine ? theme.myBubble : theme.partnerBubble,
                    author: replyAuthor,
                    onTap: onTapReply,
                  ),
                if (message.deletedForEveryone) Text(
                        'This message was deleted',
                        style: TextStyle(
                            color: theme.text,
                            fontStyle: FontStyle.italic,
                            fontSize: 14,),
                      ) else if (album != null) AlbumBubble(
                        row: album!,
                        onOpen: (i) => onOpenMedia(album!.items[i]),
                      ) else _Content(
                        message: message,
                        voice: voice,
                        textColor: theme.text,
                        bubble: mine ? theme.myBubble : theme.partnerBubble,
                        senderName: senderName,
                        onOpenMedia: onOpenMedia,
                        mine: mine,),
              ],
            ),
          ),
        ),
        // Under the bubble rather than overlapping its corner. An overlap needs
        // a Stack and a negative offset, and the chip arriving is the one
        // moment this feature can move the conversation — a row that grows
        // inside the flow is the version that cannot land on top of the
        // timestamp when a font scales.
        ReactionChips(
          // A message deleted for everyone keeps no body; it keeps no
          // reactions either. The RPC scrubs the rows server-side, but the
          // device that owns a reaction ignores its own DELETE echo, so
          // without this the sender would keep seeing — and could keep
          // tapping — a chip on a message that says it was deleted.
          byUser: message.deletedForEveryone ? const {} : (reactions ?? const {}),
          myUid: myUid,
          mine: mine,
          onTap: onReact,
        ),
        Padding(
          padding: EdgeInsets.only(
            left: mine ? 0 : 6,
            right: mine ? 6 : 0,
            bottom: 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _bubbleTimeFormat.format(message.createdAt),
                style: const TextStyle(fontSize: 10, color: MilesColors.faint),
              ),
              // Said, not hidden. A message whose text changed after it was
              // read is a different message, and the person who read the first
              // version is entitled to know a second one exists.
              if (message.editedAt != null) ...[
                const SizedBox(width: 4),
                const Text(
                  'edited',
                  style: TextStyle(
                    fontSize: 10,
                    color: MilesColors.faint,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              if (mine && status != null) ...[
                const SizedBox(width: 4),
                // Rebuilt by the 5s notifier alone, so a decaying receipt
                // costs one small widget instead of the whole conversation.
                ValueListenableBuilder<int>(
                  valueListenable: tick,
                  builder: (_, __, ___) =>
                      _StatusTick(status: status!(), onRetry: onRetry),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The highest receipt position this handset has ever seen, kept across a
/// remount so a re-entered chat never redraws backwards.
///
/// THE BUG THIS EXISTS FOR. AppShell renders `bodies[bodyIndex]` inside a plain
/// Column (app_shell.dart:441), not an IndexedStack — so changing tab DISPOSES
/// ChatScreen, and MilesApp.raiseCover() disposes it again on every background.
/// The next visit began with `_partnerReceipt` null, and `_rawStatusFor` maps
/// null to `sent`. Every message the partner had already read redrew as ONE
/// GREY TICK and stayed there for the length of one network round trip — the
/// 2-3 seconds the owner reported. Nothing was wrong with the upward clamp in
/// `_applyPartnerReceipt`: it clamps the new value against the previous one,
/// and after a remount there is no previous one.
///
/// WHY REMEMBERING IS SOUND. Both seqs are server-assigned watermarks that only
/// ever rise: `ack_delivered` and `ack_read` take the max, so the partner's
/// true position is always >= any value this device has observed. A remembered
/// value is therefore a lower bound on the truth. It can leave a tick one rung
/// low for the moment before the live value lands; it can never invent a rung
/// the partner has not actually reached. Under-stating for 200ms is a tick that
/// climbs; over-stating would be a lie about whether she has read you.
///
/// The seq pair IS the per-message high-water mark — status is a pure function
/// of (m.seq, receipt), and m.seq never changes once bound — so no per-message
/// set is needed to stop a single bubble falling back.
class _ReceiptMemory {
  _ReceiptMemory._();

  /// Mirrors what is on disk so a remount inside a live process restores on the
  /// FIRST FRAME rather than a beat later. That is the ordinary case; the disk
  /// copy only really answers after a process death.
  static final Map<String, ChatReceipt> _cache = {};

  /// What this process already knows, with no await between it and the frame.
  static ChatReceipt? peek(String key) => _cache[key];

  /// What a previous process left behind. Null when there is nothing usable.
  static Future<ChatReceipt?> load(String key) async {
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return null;
      final parts = raw.split(':');
      final d = parts.length == 2 ? int.tryParse(parts[0]) : null;
      final r = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (d == null || r == null) {
        // Never silently: an unreadable watermark is the tick flashing grey
        // again, which is the whole defect this class closes.
        debugPrint('[receipts] unreadable stored receipt for $key: "$raw"');
        return null;
      }
      final stored = ChatReceipt(deliveredSeq: d, readSeq: r);
      _cache[key] = stored;
      return stored;
    } catch (e) {
      debugPrint('[receipts] receipt memory read failed for $key: $e');
      return null;
    }
  }

  /// Record [r], keeping whichever seq is higher. A no-op when nothing rises,
  /// so the callers may hand it every observation without costing a disk write
  /// per realtime event.
  static void remember(String key, ChatReceipt r) {
    final prev = _cache[key];
    if (prev != null &&
        r.deliveredSeq <= prev.deliveredSeq &&
        r.readSeq <= prev.readSeq) {
      return;
    }
    final merged = prev == null
        ? r
        : ChatReceipt(
            deliveredSeq: r.deliveredSeq > prev.deliveredSeq
                ? r.deliveredSeq
                : prev.deliveredSeq,
            readSeq: r.readSeq > prev.readSeq ? r.readSeq : prev.readSeq,
          );
    _cache[key] = merged;
    unawaited(_persist(key, merged));
  }

  static Future<void> _persist(String key, ChatReceipt r) async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(key, '${r.deliveredSeq}:${r.readSeq}');
    } catch (e) {
      // The in-memory copy still covers a tab change, which is the common case;
      // only a cold start loses the head start. Worth knowing, never fatal.
      debugPrint('[receipts] receipt memory write failed for $key: $e');
    }
  }
}

/// Read-receipt state for a message, plus the two states a send passes through
/// before there is a row for anyone to receipt.
///
/// Three rungs, exactly as WhatsApp draws them, plus two that are not rungs:
///   sending   — still on this phone (clock icon, distinct from any tick)
///   failed    — never reached the server (ember icon + "tap to retry")
///   sent      — the SERVER has it, their phone does not      ONE GREY
///   delivered — their PHONE has it, app open or closed       TWO GREY
///   seen      — they opened the chat and saw it              TWO GREEN
enum _MsgStatus { sending, failed, sent, delivered, seen }

class _StatusTick extends StatelessWidget {
  const _StatusTick({required this.status, this.onRetry});
  final _MsgStatus status;

  /// Set only where the bubble carries no retry of its own — a photo puts a
  /// pill over the frame (:2075) and a video its own caption (:2392), so
  /// offering one here as well would be two ways to say the same thing.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case _MsgStatus.sending:
        return const Icon(Icons.schedule, size: 13, color: MilesColors.faint);
      case _MsgStatus.failed:
        if (onRetry == null) {
          return const Icon(Icons.error_outline,
              size: 13, color: MilesColors.ember,);
        }
        return GestureDetector(
          onTap: onRetry,
          behavior: HitTestBehavior.opaque,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 13, color: MilesColors.ember),
              SizedBox(width: 3),
              Text("Didn't send · tap to retry",
                  style: TextStyle(fontSize: 10, color: MilesColors.ember),),
            ],
          ),
        );
      case _MsgStatus.sent:
        return const Icon(Icons.check, size: 13, color: MilesColors.faint);
      case _MsgStatus.delivered:
        return const Icon(Icons.done_all, size: 13, color: MilesColors.faint);
      case _MsgStatus.seen:
        return const Icon(Icons.done_all, size: 13, color: MilesColors.sage);
    }
  }
}
class _ActiveBurst {
  _ActiveBurst(this.id, {this.mood, this.gifUrl});
  final int id;
  final MoodData? mood;
  final String? gifUrl;
}

/// A "fling" — a big animated emoji OR a GIF that rises up the chat and fades,
/// on both phones in real time (sent over an ephemeral broadcast channel).
class _BurstAnimation extends StatefulWidget {
  const _BurstAnimation({
    required this.onDone, super.key,
    this.mood,
    this.gifUrl,
  });
  final MoodData? mood;
  final String? gifUrl;
  final VoidCallback onDone;

  @override
  State<_BurstAnimation> createState() => _BurstAnimationState();
}

class _BurstAnimationState extends State<_BurstAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.gifUrl != null ? 5200 : 1900),
  )..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          // The payload never changes over the animation — only its opacity,
          // offset and scale do. Passing it as `child` builds it once instead
          // of reconstructing an Image.network on every frame for ~5s.
          child: widget.gifUrl != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.network(
                    widget.gifUrl!,
                    width: 160,
                    height: 160,
                    // Layout-only without this. fullUrl is downsized_medium at
                    // best and `original` at worst — several MB, at source
                    // resolution, decoding a frame every ~25ms for the 5.2s the
                    // burst is held, Positioned.fill, on both phones, during
                    // exactly the scroll this is meant to feel smooth in.
                    cacheWidth: 320,
                    fit: BoxFit.cover,
                  ),
                )
              : (widget.mood != null
                  ? AnimatedMood(mood: widget.mood!, size: 92)
                  : const SizedBox.shrink()),
          builder: (context, child) {
            final v = _c.value;
            final isGif = widget.gifUrl != null;
            // GIFs: fade in fast, HOLD on screen while the GIF plays, fade out
            // at the very end. Moods: the quick rise-and-fade.
            final opacity = isGif
                ? (v < 0.08
                    ? v / 0.08
                    : (v < 0.85 ? 1.0 : (1 - (v - 0.85) / 0.15)))
                : (v < 0.15 ? v / 0.15 : (1 - (v - 0.15) / 0.85));
            // GIFs drift up gently and linger near centre; moods rise away.
            final dy = isGif ? 0.22 - v * 0.42 : 0.4 - v * 1.1;
            final scale = isGif ? 0.9 + v * 0.18 : 0.6 + v * 0.9;
            return Align(
              alignment: Alignment(0, dy),
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: scale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: (widget.mood?.color ?? MilesColors.blush)
                              .withValues(alpha: 0.5),
                          blurRadius: 30,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Built once, not per bubble per build. Constructing a DateFormat costs
/// ~23.6us against ~0.9us for a cached one, and a 300-message conversation
/// paid it twice per visible row on every rebuild.
final DateFormat _dayHeaderFormat = DateFormat('EEEE, MMM d');
final DateFormat _bubbleTimeFormat = DateFormat('h:mm a');

/// Small quoted preview shown at the top of a bubble that's replying.
///
/// It used to be a bare Container holding one line of preview text: no author,
/// no tap. Between two people sending five voice notes each, "yes, exactly"
/// under an unattributed line answers nothing anyone can point at — so the card
/// now says WHO, and tapping it walks the conversation back to the message
/// itself.
class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.message,
    required this.on,
    this.author,
    this.onTap,
  });
  final Message message;

  /// The bubble this sits inside. The quote is a shade of its host, and the
  /// host is whichever of a dozen chat themes the couple picked — resolving
  /// the shade here is the only way to darken it without going see-through.
  final Color on;

  /// 'You' or the partner's name. Null only when the quoted message is not
  /// loaded, which is also when there is nobody to name.
  final String? author;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: MilesColors.tint(Colors.black, 0.18, over: on),
          borderRadius: BorderRadius.circular(8),
          border: const Border(
            left: BorderSide(color: MilesColors.gilt, width: 3),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (author != null)
              Text(
                author!,
                style: const TextStyle(
                  color: MilesColors.gilt,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            Text(
              message.previewText(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: MilesColors.cream50, fontSize: 12, height: 1.2,),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the inside of a bubble based on message kind.
class _Content extends StatelessWidget {
  const _Content({
    required this.message,
    required this.voice,
    required this.senderName,
    required this.bubble,
    required this.onOpenMedia,
    required this.mine,
    this.textColor = MilesColors.cream50,
  });
  final Message message;
  final VoiceNotePlayer voice;
  final String senderName;

  /// Opens the pager on this message, inside the conversation's whole media
  /// set. Replaces the single-path open that gave a photo no neighbours.
  final void Function(Message) onOpenMedia;

  /// Whose note this is. Only the partner's can be unplayed.
  final bool mine;

  /// The fill of the bubble this is rendering inside — a dozen chat themes
  /// pick it, and controls drawn on top have to resolve against it rather
  /// than let a wash of white stand in for one.
  final Color bubble;
  final Color textColor;

  /// Toggle this note, and say so if it will not open.
  static Future<void> _play(BuildContext context, VoiceNotePlayer voice,
      String id, String url,) async {
    try {
      await voice.toggle(id, url);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play voice note.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    switch (m.kind) {
      case 'image':
        final local = m.localPath;
        final url = m.imageUrl;
        if (local == null && url == null) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text('📷 image unavailable',
                style: TextStyle(color: MilesColors.cream50, fontSize: 14),),
          );
        }
        // Optimistic: render the local file instantly while it uploads; the
        // partner (no localPath) gets the network image.
        // The single most-rendered image in the app, and it was the slowest
        // widget available. Image.network has NO disk cache, so every photo
        // re-downloaded on every cold start; `width: 220` is layout only, so a
        // 3000x4000 upload decoded at full resolution — ~48MB of RAM — into a
        // 220dp slot; and Flutter's in-memory cache was keyed on a signed URL
        // whose token rotates daily, so it re-downloaded every morning too.
        // NetImage disk-caches under the stable storage path and bounds the
        // decode. A single photo never gets an album_id
        // (chat_send_queue.dart:145), so this is the common case, not the rare
        // one — the album grid was already on this path and this bubble was not.
        final tile = m.tileUrl;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final Widget img = local != null
            ? Image.file(File(local),
                width: 220,
                // Layout-only without this: the sender's own phone decoded the
                // full-sensor file it had just picked.
                cacheWidth: (220 * dpr).round(),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const SizedBox(width: 220, height: 140),)
            : m.isAnimated
                // Stays Image.network: some CachedNetworkImage configurations
                // hand back one frame and the animation dies. cacheWidth is
                // independent of which loader is used.
                ? Image.network(url!,
                    width: 220,
                    cacheWidth: (220 * dpr).round(),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox(
                        width: 220, height: 140,),)
                : NetImage(
                    tile ?? url!,
                    width: 220,
                    cacheKey: m.tileCacheKey,
                    thumb: m.hasThumb,
                  );
        return GestureDetector(
          // The PATH, not the URL it is currently signed as: the viewer holds
          // this for as long as it is open and a token dies in a day.
          onTap: url == null ? null : () => onOpenMedia(m),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                if (url != null)
                  Hero(
                    // The viewer tags its pages '<bucket>/<path>'
                    // (media_source.dart). This was the raw signed URL, so the
                    // tags never matched and the flight silently did not happen.
                    tag: '$chatBucket/'
                        '${MediaUrls.toPath(chatBucket, m.imagePath ?? '')}',
                    child: img,
                  )
                else
                  img,
                if (m.sendStatus == SendStatus.sending)
                  const Positioned.fill(
                    child: ColoredBox(
                      // A scrim over the photo itself, which stays visible
                      // under the spinner while it uploads.
                      color: Color(0x55000000),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white,),
                        ),
                      ),
                    ),
                  ),
                // Tappable, not decorative. This used to be a bare icon with
                // no gesture and the surrounding onTap null (no url yet), so a
                // photo that failed to upload was silently, permanently gone.
                if (m.sendStatus == SendStatus.failed)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: GestureDetector(
                      onTap: () => ChatSendQueue.instance.retry(m.id),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6,),
                        decoration: BoxDecoration(
                          // A scrim over the photo that failed — the retry has
                          // to read against whatever was in the frame.
                          color: const Color(0xCC1A0E12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: const Color(0xFFE0564B),),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.refresh_rounded,
                                color: Color(0xFFE0564B), size: 16,),
                            SizedBox(width: 5),
                            Text('Retry',
                                style: TextStyle(
                                    color: Color(0xFFE0564B),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,),),
                          ],
                        ),
                      ),
                    ),
                  ),
                // Save-to-gallery — only once uploaded (url available).
                if (url != null && m.sendStatus == SendStatus.sent)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: SurfacePanel(
                      radius: 12,
                      color: MilesColors.scrim,
                      padding: const EdgeInsets.all(4),
                      child: SaveMediaButton(
                        size: 18,
                        onSave: () => SaveMediaService.savePhotoToVault(
                            url: url, senderName: senderName,),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      case 'voice':
        final url = m.voiceUrl;
        if (url == null) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text('🎙️ voice unavailable',
                style: TextStyle(color: MilesColors.cream50, fontSize: 14),),
          );
        }
        // Rebuilt on every player change so the icon follows THIS note. The
        // listen is here rather than around the whole list: a note playing
        // must not rebuild three hundred bubbles.
        return ListenableBuilder(
          listenable: voice,
          builder: (context, _) => VoiceNoteBubble(
            url: url,
            playing: voice.isPlaying(m.id),
            onToggle: () => _play(context, voice, m.id, url),
            senderName: senderName,
            bubble: bubble,
            durationMs: m.voiceDurationMs,
            positionStream: voice.positionStream,
            peaks: VoicePeaks.decode(m.voicePeaks),
            messageId: m.id,
            speed: voice.speed,
            onCycleSpeed: () => unawaited(voice.cycleSpeed()),
            playerTotal: voice.totalOf(m.id),
            onSeek: (at) => unawaited(voice.seek(m.id, url, at)),
            // Held only while a finger is on the waveform, and read by the
            // list to stand that row's swipe-to-reply down for the duration.
            onScrub: ({required active}) =>
                voice.scrubbing.value = active ? m.id : null,
            // Only the partner's. A dot on your own note would be telling you
            // that you have not listened to yourself.
            unplayed: !mine && !voice.wasPlayed(m.id),
          ),
        );
      case 'video':
        return _VideoBubble(message: m, senderName: senderName);
      case 'file':
        return FileBubble(message: m);
      default:
        // Ciphertext this device cannot open. An empty bubble here is
        // indistinguishable from a message that was deleted, or from a bug, so
        // it says so instead — and says the one thing that actually resolves
        // it, which is that the other device holds the key.
        if (m.bodyUndecryptable) {
          return Text(
            "Can't open this message on this device",
            style: TextStyle(
              color: textColor.withValues(alpha: 0.7),
              fontSize: 15,
              height: 1.35,
              fontStyle: FontStyle.italic,
            ),
          );
        }
        final body = m.body ?? '';
        final spans = LinkScan.spans(body);
        final style = TextStyle(
          color: textColor,
          fontSize: 15,
          height: 1.35,
        );
        if (spans.isEmpty) return Text(body, style: style);

        // Linkified text, plus a card for the first link. A plain Text was the
        // whole of this branch, so a shared reel was an unclickable string the
        // partner had to select, copy and paste into a browser by hand.
        final linkStyle = style.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: textColor.withValues(alpha: 0.55),
        );
        final pieces = <InlineSpan>[];
        var at = 0;
        for (final sp in spans) {
          if (sp.start > at) {
            pieces.add(TextSpan(text: body.substring(at, sp.start)));
          }
          final target = classifyLink(sp.url);
          pieces.add(TextSpan(
            text: body.substring(sp.start, sp.end),
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => LinkOpen.open(context, target),
          ),);
          at = sp.end;
        }
        if (at < body.length) pieces.add(TextSpan(text: body.substring(at)));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(TextSpan(style: style, children: pieces)),
            LinkCard(target: classifyLink(spans.first.url), onBubble: true),
          ],
        );
    }
  }
}

/// The themed chat background: a gradient/solid colour, or — for the 'custom'
/// theme — the user's photo with a dark scrim so message text stays readable.
class _ChatBg extends StatelessWidget {
  const _ChatBg({required this.theme, required this.bgPath});
  final ChatTheme theme;
  final String? bgPath;

  @override
  Widget build(BuildContext context) {
    if (theme.isCustom && bgPath != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // Bounded on BOTH edges, and on the LONG one. Without any bound
          // SignedImage passes null through to memCacheWidth and the wallpaper
          // decodes at whatever the user uploaded — full resolution, resident
          // behind every frame of the scrolling list. Bounding the short edge
          // instead would be worse than nothing: this is BoxFit.cover on a
          // full-bleed image, so the short edge is the one that gets upscaled.
          SignedImage(
            bucket: chatBgBucket,
            value: bgPath,
            width: MediaQuery.sizeOf(context).width,
            height: MediaQuery.sizeOf(context).height,
            placeholder: const ColoredBox(color: MilesColors.night),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x59000000), Color(0xA6000000)],
              ),
            ),
          ),
        ],
      );
    }
    return ChatBackdrop(theme: theme);
  }
}

/// "↓ New message" pill shown when a message arrives while the user is scrolled
/// up reading history — taps to jump to the newest.
class _NewMessageChip extends StatelessWidget {
  const _NewMessageChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: MilesColors.ember,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: MilesColors.ember.withValues(alpha: 0.4),
                blurRadius: 12,
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 16, color: MilesColors.cream50),
              SizedBox(width: 6),
              Text('New message',
                  style: TextStyle(color: MilesColors.cream50, fontSize: 12),),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tap-to-play thumbnail for a private video message → full-screen player.
class _VideoBubble extends StatefulWidget {
  const _VideoBubble({required this.message, required this.senderName});
  final Message message;
  final String senderName;

  String? get path => message.videoPath;

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  bool _loading = false;

  /// One viewer for everything. A second full-screen player would be a second
  /// place FLAG_SECURE has to be remembered, and couple_intimate is the one
  /// bucket in this app that exists to stop a screenshot.
  Future<void> _open() async {
    final path = widget.path;
    if (path == null) return;
    setState(() => _loading = true);
    // Not for the URL — the viewer signs. This is the "is it actually there"
    // check the bubble already made, and the snackbar it already showed.
    final url = await ChatRepository.signedVideoUrl(path);
    if (!mounted) return;
    setState(() => _loading = false);
    if (url == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Video unavailable')));
      return;
    }
    await MediaViewer.openStored(context, privateBucket, path,
        isVideo: true, senderName: widget.senderName,);
  }

  @override
  Widget build(BuildContext context) {
    // An outgoing video has no thumbnail and no signed URL yet, so without
    // these it sat as a black tile with a play button that did nothing — for
    // as long as the upload took, and forever if it failed.
    final sending = widget.message.sendStatus == SendStatus.sending;
    final failed = widget.message.sendStatus == SendStatus.failed;
    final poster = sending ? null : widget.message.tileUrl;
    return Stack(
      children: [
        GestureDetector(
          onTap: failed
              ? () => ChatSendQueue.instance.retry(widget.message.id)
              : ((_loading || sending) ? null : _open),
          child: Container(
            width: 220,
            height: 140,
            decoration: BoxDecoration(
              // Stands in for the video frame itself while it uploads, so it
              // is the frame's own black rather than a wash over the chat.
              color: MilesColors.night,
              borderRadius: BorderRadius.circular(14),
            ),
            // The poster frame is extracted on send, uploaded beside the video
            // and warmed with the page (chat_repository) — and then the bubble
            // painted a black rectangle over it and never read it. A video in
            // the conversation was indistinguishable from a video that failed.
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (poster != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: NetImage(
                      poster,
                      width: 220,
                      height: 140,
                      cacheKey: widget.message.tileCacheKey,
                      thumb: true,
                    ),
                  ),
                Center(
              child: _loading || sending
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),)
                  : Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: failed
                              ? MilesColors.ember
                              : MilesColors.blush,),
                      child: Icon(
                          failed ? Icons.refresh_rounded : Icons.play_arrow,
                          color: MilesColors.cream50,
                          size: 30,),
                    ),
                ),
              ],
            ),
          ),
        ),
        if (failed)
          const Positioned(
            left: 8,
            bottom: 8,
            child: Text("Didn't send · tap to retry",
                style: TextStyle(color: MilesColors.ember, fontSize: 11),),
          ),
        if (widget.path != null)
          Positioned(
            bottom: 6,
            right: 6,
            child: SurfacePanel(
              radius: 12,
              color: MilesColors.scrim,
              padding: const EdgeInsets.all(4),
              child: SaveMediaButton(
                size: 18,
                onSave: () => SaveMediaService.saveVideoToVault(
                    path: widget.path!, senderName: widget.senderName,),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💌', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 16),
            Text('Say something sweet',
                style: Theme.of(context).textTheme.displaySmall,),
            const SizedBox(height: 8),
            const Text(
              'This is your private space — just the two of you. '
              'Send the first message, snap a photo, or hold the mic to talk.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotLinked extends StatelessWidget {
  const _NotLinked();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Link with your partner first to start chatting.',
          textAlign: TextAlign.center,
          style: TextStyle(color: MilesColors.taupe),
        ),
      ),
    );
  }
}
