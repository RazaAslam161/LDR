import 'dart:async';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/core/widgets/animated_mood.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/chat/chat_input_bar.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_selection.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:miles/features/chat/selectable_message.dart';
import 'package:miles/features/chat/chat_theme.dart';
import 'package:miles/features/chat/chat_theme_controller.dart';
import 'package:miles/features/chat/chat_theme_picker.dart';
import 'package:miles/features/chat/giphy_picker.dart';
import 'package:miles/features/chat/media_viewer.dart';
import 'package:miles/features/chat/mood_selector.dart';
import 'package:miles/features/chat/typing_indicator.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

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
  Timer? _readTimer;
  bool _typingActive = false;
  bool _hasNewMessage = false;
  Message? _replyingTo;
  RealtimeChannel? _moodChannel;

  /// Local-only "clear conversation" cutoff: messages at or before this are
  /// hidden on THIS device. Never synced — the partner is unaffected.
  DateTime? _clearedBefore;

  /// Messages picked for a bulk action. Empty means not in selection mode —
  /// there is no separate flag to fall out of sync with the set itself.
  final _selection = ChatSelection();
  bool get _selecting => _selection.isActive;
  bool _subscribing = false; // re-entrancy guard for _subscribe
  bool _reloadScheduled = false; // debounce flag for bulk-DELETE realtime events

  /// IDs of my messages that have reached 'seen'. Seen is permanent — once a
  /// message is in here it never downgrades back to delivered, even after the
  /// partner leaves the chat / goes offline (WhatsApp semantics). Only grows.
  final Set<String> _seenMessageIds = {};
  final List<_ActiveBurst> _bursts = [];
  int _burstId = 0;
  static const _uuid = Uuid();

  /// Send text with INSTANT feedback: show it locally now (optimistic), push it
  /// to the partner over realtime broadcast (fast), and persist to the DB. All
  /// three carry the same id, so the postgres echo + broadcast dedupe cleanly.
  Future<void> _sendTextFast(String coupleId, String t) async {
    final body = t.trim();
    if (body.isEmpty) return;
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
        kind: 'text',
        replyToId: replyId,
      ));
    }
    _moodChannel?.sendBroadcastMessage(event: 'msg', payload: {
      'id': id,
      'sender': myUid,
      'body': body,
      'createdAt': now.toUtc().toIso8601String(),
      'replyToId': replyId,
    });
    try {
      await ChatRepository.sendText(coupleId, body, id: id, replyToId: replyId);
    } catch (_) {
      /* it's already on screen; the DB retry isn't worth blocking */
    }
  }

  /// A text message pushed by the partner over broadcast — shown immediately,
  /// then deduped when the slower postgres echo arrives (same id).
  void _onMsgBroadcast(Map<String, dynamic> payload) {
    final id = payload['id']?.toString();
    final sender = payload['sender']?.toString();
    if (id == null || sender == null) return;
    final created =
        DateTime.tryParse(payload['createdAt']?.toString() ?? '')?.toLocal() ??
            DateTime.now();
    final kind = payload['kind']?.toString() ?? 'text';
    _onIncoming(Message(
      id: id,
      senderId: sender,
      createdAt: created,
      kind: kind,
      body: kind == 'text' ? payload['body']?.toString() : null,
      imagePath: kind == 'image' ? payload['imagePath']?.toString() : null,
      replyToId: payload['replyToId']?.toString(),
    ));
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
      _sendGifBurst(url);
    } catch (_) {}
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
      if (res.statusCode != 200) return;
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

  /// Mirror the queue's pending sends into the message list.
  ///
  /// Called on mount and whenever the queue changes, so a photo taken from the
  /// shell's camera tab is already a bubble by the time the user reaches the
  /// chat — and a failure becomes a retryable bubble instead of vanishing.
  void _adoptPending() {
    final myUid = SupabaseService.currentUserId;
    final coupleId = _coupleId;
    if (myUid == null || coupleId == null || !mounted) return;

    for (final s in ChatSendQueue.instance.pending) {
      if (s.coupleId != coupleId) continue;
      final i = _messages.indexWhere((m) => m.id == s.id);
      if (i >= 0) {
        if (_messages[i].sendStatus != s.status) {
          setState(() =>
              _messages[i] = _messages[i].copyWith(sendStatus: s.status));
        }
        continue;
      }
      _onIncoming(Message(
        id: s.id,
        senderId: myUid,
        createdAt: DateTime.now(),
        kind: s.kind,
        localPath: s.file.path,
        sendStatus: s.status,
        replyToId: s.replyToId,
      ));
    }

    // Anything the queue has finished with is either reconciled by the DB echo
    // or gone; flip a lingering 'sending' bubble so it can't spin forever.
    final live = {for (final s in ChatSendQueue.instance.pending) s.id};
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.localPath != null &&
          m.sendStatus == SendStatus.sending &&
          !live.contains(m.id)) {
        setState(() =>
            _messages[i] = _messages[i].copyWith(sendStatus: SendStatus.sent));
      }
    }
  }

  void _startReply(Message m) {
    if (m.deletedForEveryone) return;
    setState(() => _replyingTo = m);
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// The id to attach to the next send (and clears the reply state).
  String? _takeReplyId() {
    final id = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    return id;
  }

  /// Find a loaded message by id (for rendering a quoted reply preview).
  Message? _byId(String? id) {
    if (id == null) return null;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  // Voice recorder
  final _audioRecorder = AudioRecorder();
  final _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    realtimeResumed.addListener(_subscribe); // rejoin on any socket reconnect
    // Sends can start anywhere — the shell's camera tab opens with this screen
    // unmounted — so the chat follows the queue rather than owning it.
    ChatSendQueue.instance.addListener(_adoptPending);
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
      PresenceService.setChatLastRead(_coupleId!);
    }
  }

  /// Subscribe (or cleanly RE-subscribe) the chat's realtime channels. Idempotent
  /// and re-entrancy-guarded: the old channels are FULLY removed (awaited) before
  /// the new ones join. Supabase's `channel()` never dedupes by topic and
  /// `unsubscribe()` leaves the old channel registered until its async leave
  /// acks — so `unsubscribe()` + immediate re-`channel()` created duplicate-topic
  /// channels whose join was rejected, leaving them joined-but-dead (no live
  /// render). removeChannel() awaits the leave first, so the re-join is clean.
  Future<void> _subscribe() async {
    final id = _coupleId;
    if (id == null || !mounted || _subscribing) return;
    _subscribing = true;
    try {
      final client = SupabaseService.client;
      final old1 = _channel, old2 = _moodChannel;
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
      if (!mounted) return;
      _channel = ChatRepository.subscribe(
        id,
        (m) => _onIncoming(m, fromDb: true),
        onDelete: _onRemoteDelete,
      );
      _moodChannel = client
          .channel('mood_burst:$id')
          .onBroadcast(event: 'mood', callback: _onMoodBurst)
          .onBroadcast(event: 'msg', callback: _onMsgBroadcast)
          .onBroadcast(event: 'typing', callback: _onTypingBroadcast)
          .onBroadcast(event: 'cleared', callback: _onClearedBroadcast)
          .subscribe();
      // Let other screens (e.g. the rapid camera) push the fast-path on THIS
      // live channel instead of creating a duplicate-topic one.
      ChatBroadcastService.active = _moodChannel;
      PresenceService.setChatLastRead(id);
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
    _clearedBefore = await _loadClearedBefore(couple.id);
    try {
      final msgs = await ChatRepository.fetch(couple.id);
      _messages.addAll(msgs);
      _sortMessages();
      _ids.addAll(msgs.map((m) => m.id));
      _seedSeenLatch();
    } catch (_) {
      // first-run is fine
    }
    await _subscribe(); // single, idempotent channel-subscribe path
    // Photos taken from the shell's camera tab were already uploading before
    // this screen existed — show them now rather than when they land.
    _adoptPending();
    PresenceService.setOnline(couple.id, online: true);
    PresenceService.setTypingInChat(couple.id, inChat: true);
    // Read-receipts + "in chat" avatar: mark read now and keep it fresh while
    // the chat is open (the shell only keeps this screen alive while viewing).
    PresenceService.setChatLastRead(couple.id);
    _readTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      PresenceService.setChatLastRead(couple.id);
      setState(() {}); // refresh time-based receipts + "is here" indicator
    });
    if (mounted) setState(() => _loading = false);
    // reverse:true already pins the view to the newest message — no scroll needed.
  }

  void _onIncoming(Message m, {bool fromDb = false}) {
    if (kRtChatDebug) {
      debugPrint('[rt] incoming id=${m.id} fromDb=$fromDb kind=${m.kind}');
    }
    if (_ids.contains(m.id)) {
      // Already shown (optimistic / broadcast). When the authoritative DB row
      // arrives, adopt its SERVER timestamp + paths so ordering is correct
      // across devices and the status flips to sent.
      if (fromDb && mounted) {
        final i = _messages.indexWhere((x) => x.id == m.id);
        if (i >= 0) {
          setState(() {
            _messages[i] = _messages[i].reconcileWith(m);
            _sortMessages();
          });
        }
      }
      return;
    }
    _ids.add(m.id);
    if (!mounted) return;
    final mine = m.isMine(SupabaseService.currentUserId);
    // I'm viewing the chat, so the partner's new message is read immediately.
    if (!mine && _coupleId != null) {
      PresenceService.setChatLastRead(_coupleId!);
    }
    final atBottom = _isAtBottom();
    setState(() {
      _messages.insert(0, m); // newest-first ordering
      _sortMessages();
    });
    // Don't yank a user who's reading history; show a chip instead.
    if (mine || atBottom) {
      _scrollToNewest();
    } else {
      setState(() => _hasNewMessage = true);
    }
  }

  Future<void> _videoCall() async {
    // In-app WebRTC call. The shell listens for the state change and pushes the
    // call screen; the partner's app rings if it's open.
    await ref.read(callControllerProvider).startCall(video: true);
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
            duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
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
    final m = await showMoodSelector(context);
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
      });
      _seedSeenLatch();
    } catch (_) {}
  }

  /// Seeds the permanent "seen" latch from history so seen survives a reload /
  /// reopen: any of MY messages at or before the partner's current chat_last_read
  /// have definitely been seen. Without this, a reload would briefly recompute
  /// old seen messages as delivered until the next presence tick.
  void _seedSeenLatch() {
    final read = ref.read(partnerPresenceProvider)?.chatLastRead;
    if (read == null) return;
    final myUid = SupabaseService.currentUserId;
    for (final m in _messages) {
      if (m.isMine(myUid) && !m.createdAt.isAfter(read)) {
        _seenMessageIds.add(m.id);
      }
    }
  }

  /// Read-receipt status for one of MY messages. Seen is LATCHED: once true it
  /// stays true forever (never downgrades to delivered when the partner leaves).
  _MsgStatus _statusFor(Message m, Presence? p) {
    // LATCH: if this message was ever seen, it stays seen.
    if (_seenMessageIds.contains(m.id)) return _MsgStatus.seen;

    // SEEN is a WATERMARK COMPARISON and nothing else. chat_last_read only ever
    // moves forward, so "she had read up to here" cannot stop being true.
    //
    // This used to also require isActivelyInChat — live presence. The moment
    // she closed the chat that went false, and every message not already
    // latched in memory fell back to a black double tick. Whether a message has
    // been read is durable; whether she is looking right now is not. Mixing
    // them made the durable fact expire.
    final seenNow = p?.chatLastRead != null &&
        p!.chatLastRead!
            .isAfter(m.createdAt.subtract(const Duration(seconds: 1)));
    if (seenNow) {
      _seenMessageIds.add(m.id);
      return _MsgStatus.seen;
    }

    // DELIVERED: partner genuinely online right now (freshness-gated), not the
    // stored is_online bool which never expires on a hard kill.
    if (p != null && p.isTrulyOnline) return _MsgStatus.delivered;

    // SENT: partner offline or status stale. Safe default.
    return _MsgStatus.sent;
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
          path: m.videoPath!, senderName: sender);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            success ? 'Saved to your vault 🔒' : 'Could not save to vault'),
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

  void _clearSelection() => setState(_selection.clear);

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
        : ChatRepository.deleteForMe);
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
                'selected.'),
      ));
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
      backgroundColor: Colors.transparent,
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
                    fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.visibility_off, color: MilesColors.taupe),
              title: const Text('Delete for me',
                  style: TextStyle(color: MilesColors.cream50)),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (mineOnly)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Color(0xFFB83A57)),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: Color(0xFFB83A57))),
                onTap: () => Navigator.pop(ctx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.close, color: MilesColors.faint),
              title: const Text('Cancel',
                  style: TextStyle(color: MilesColors.taupe)),
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
        backgroundColor: Colors.transparent,
        title: const Text('Clear conversation?'),
        content: Text(
          'This will permanently delete all messages for both you and '
          '$partnerName. This cannot be undone.',
          style: const TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: MilesColors.ember),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete for everyone')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ChatRepository.clearConversation();
      // Instant fan-out to the partner over the live broadcast channel (same
      // reliable path as typing/msg). Postgres DELETE realtime is the backstop.
      _moodChannel?.sendBroadcastMessage(event: 'cleared', payload: const {});
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
            const SnackBar(content: Text('Could not clear the conversation.')));
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
    ChatSendQueue.instance.removeListener(_adoptPending);
    _typingTimer?.cancel();
    _partnerTypingTimer?.cancel();
    _readTimer?.cancel();
    final id = _coupleId;
    if (id != null) {
      PresenceService.setTyping(id, typing: false);
      PresenceService.setTypingInChat(id, inChat: false);
    }
    final client = SupabaseService.client;
    final c1 = _channel, c2 = _moodChannel;
    if (ChatBroadcastService.active == c2) ChatBroadcastService.active = null;
    if (c1 != null) client.removeChannel(c1);
    if (c2 != null) client.removeChannel(c2);
    _scroll.dispose();
    _audioRecorder.dispose();
    _player.dispose();
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
    final chatBgUrl = themeCtrl.bgUrl;
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
          title: Column(
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
                            fontWeight: FontWeight.w600)),
                  ),
                  if (partnerMood != null) ...[
                    const SizedBox(width: 8),
                    AnimatedMood(mood: partnerMood, size: 20),
                  ],
                ],
              ),
              if (partnerName != null)
                _ChatSubtitle(presence: presence, partnerTyping: _partnerTyping),
            ],
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
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'mood', child: Text('Set your mood')),
                  PopupMenuItem(value: 'gif', child: Text('Fling a GIF 🎞️')),
                  PopupMenuItem(value: 'theme', child: Text('Chat theme')),
                  PopupMenuItem(
                      value: 'clear', child: Text('Clear conversation')),
                ],
              ),
          ],
        ),
        body: couple == null
            ? const _NotLinked()
            : Stack(
                children: [
                  Positioned.fill(
                      child: _ChatBg(theme: chatTheme, bgUrl: chatBgUrl)),
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
                                  horizontal: 8, vertical: 6),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.close,
                                        color: MilesColors.cream50),
                                    onPressed: _clearSelection,
                                  ),
                                  Text(
                                    '${_selection.length} selected',
                                    style: const TextStyle(
                                        color: MilesColors.cream50,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const Spacer(),
                                  if (one != null) ...[
                                    IconButton(
                                      tooltip: 'Reply',
                                      icon: const Icon(Icons.reply,
                                          color: MilesColors.emberSoft),
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
                                            color: MilesColors.cream50),
                                        onPressed: () {
                                          _clearSelection();
                                          _saveMessageMedia(one);
                                        },
                                      ),
                                  ],
                                  IconButton(
                                    tooltip: 'Delete selected',
                                    icon: const Icon(Icons.delete_outline,
                                        color: Color(0xFFB83A57)),
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
                                    final cleared = _clearedBefore;
                                    final visible = _messages
                                        .where((m) => !m.isHiddenFor(uid))
                                        .where((m) =>
                                            cleared == null ||
                                            m.createdAt.isAfter(cleared))
                                        .toList();
                                    if (visible.isEmpty)
                                      return const _EmptyChat();
                                    return Stack(
                                      children: [
                                        ListView.builder(
                                          controller: _scroll,
                                          reverse: true,
                                          padding: const EdgeInsets.fromLTRB(
                                              16, 12, 16, 12),
                                          itemCount: visible.length,
                                          itemBuilder: (_, i) {
                                            final m = visible[i];
                                            // Descending list: the older neighbour is
                                            // i+1, so a date header marks the oldest
                                            // message of each day (top of the group).
                                            final showTime =
                                                i == visible.length - 1 ||
                                                    !DateUtils.isSameDay(
                                                        visible[i + 1].createdAt,
                                                        m.createdAt);
                                            return Dismissible(
                                                key: ValueKey('rpl-${m.id}'),
                                                direction:
                                                    DismissDirection.startToEnd,
                                                dismissThresholds: const {
                                                  DismissDirection.startToEnd:
                                                      0.22
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
                                                        color: MilesColors.blush),
                                                  ),
                                                ),
                                                child: SelectableMessage(
                                                  selecting: _selecting,
                                                  selected:
                                                      _selection.contains(m.id),
                                                  onToggle: () =>
                                                      _toggleSelected(m.id),
                                                  child: _Bubble(
                                                    message: m,
                                                    mine: m.isMine(uid),
                                                    showDateHeader: showTime,
                                                    repliedTo: _byId(m.replyToId),
                                                    player: _player,
                                                    theme: chatTheme,
                                                    senderName: m.isMine(uid)
                                                        ? 'you'
                                                        : (partnerName ??
                                                            'your partner'),
                                                    status: m.isMine(uid)
                                                        ? _statusFor(m, presence)
                                                        : null,
                                                  ),
                                                ));
                                          },
                                        ),
                                        if (_hasNewMessage)
                                          Positioned(
                                            bottom: 12,
                                            left: 0,
                                            right: 0,
                                            child: Center(
                                              child: _NewMessageChip(
                                                onTap: () {
                                                  setState(() =>
                                                      _hasNewMessage = false);
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
                                  }),
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
                        onSendText: (t) => _sendTextFast(couple.id, t),
                        onSendImage: (f) async => _sendImageFast(couple.id, f),
                        onSendVoice: (f) => ChatRepository.sendVoice(couple.id, f,
                            replyToId: _takeReplyId()),
                        onSendVideo: (f) => ChatRepository.sendVideo(couple.id, f,
                            replyToId: _takeReplyId()),
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
          style: TextStyle(fontSize: 11, color: MilesColors.taupe));
    }
    // Only show typing if the partner is genuinely online — prevents a stale
    // typing flag (left over after they left) from showing "typing…" forever.
    if ((partnerTyping || (p.isTyping && p.typingInChat)) && p.isTrulyOnline) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('typing',
              style: TextStyle(fontSize: 11, color: MilesColors.sage)),
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
              style: TextStyle(fontSize: 11, color: MilesColors.sage)),
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
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showDateHeader,
    required this.player,
    required this.theme,
    required this.senderName,
    this.repliedTo,
    this.status,
  });

  final Message message;
  final bool mine;
  final bool showDateHeader;
  final AudioPlayer player;
  final ChatTheme theme;
  final String senderName;
  final Message? repliedTo;
  final _MsgStatus? status;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showDateHeader)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                DateFormat('EEEE, MMM d').format(message.createdAt),
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
              maxWidth: MediaQuery.of(context).size.width * 0.74,
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
                if (repliedTo != null) _ReplyPreview(message: repliedTo!),
                message.deletedForEveryone
                    ? Text(
                        'This message was deleted',
                        style: TextStyle(
                            color: theme.text,
                            fontStyle: FontStyle.italic,
                            fontSize: 14),
                      )
                    : _Content(
                        message: message,
                        player: player,
                        textColor: theme.text,
                        senderName: senderName),
              ],
            ),
          ),
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
                DateFormat('h:mm a').format(message.createdAt),
                style: const TextStyle(fontSize: 10, color: MilesColors.faint),
              ),
              if (mine && status != null) ...[
                const SizedBox(width: 4),
                _StatusTick(status: status!),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Read-receipt state for a sent message.
enum _MsgStatus { sent, delivered, seen }

class _StatusTick extends StatelessWidget {
  const _StatusTick({required this.status});
  final _MsgStatus status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
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
    super.key,
    this.mood,
    this.gifUrl,
    required this.onDone,
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

/// Small quoted preview shown at the top of a bubble that's replying.
class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: MilesColors.gilt, width: 3),
        ),
      ),
      child: Text(
        message.previewText(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
            color: MilesColors.cream50, fontSize: 12, height: 1.2),
      ),
    );
  }
}

/// Renders the inside of a bubble based on message kind.
class _Content extends StatelessWidget {
  const _Content({
    required this.message,
    required this.player,
    required this.senderName,
    this.textColor = MilesColors.cream50,
  });
  final Message message;
  final AudioPlayer player;
  final String senderName;
  final Color textColor;

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
                style: TextStyle(color: MilesColors.cream50, fontSize: 14)),
          );
        }
        // Optimistic: render the local file instantly while it uploads; the
        // partner (no localPath) gets the network image.
        final Widget img = local != null
            ? Image.file(File(local),
                width: 220,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const SizedBox(width: 220, height: 140))
            : Image.network(
                url!,
                width: 220,
                fit: BoxFit.cover,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const SizedBox(
                        width: 220,
                        height: 140,
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('📷 could not load',
                      style:
                          TextStyle(color: MilesColors.cream50, fontSize: 14)),
                ),
              );
        return GestureDetector(
          onTap: url == null
              ? null
              : () => MediaViewer.open(context, url,
                  heroTag: url, senderName: senderName),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                if (url != null) Hero(tag: url, child: img) else img,
                if (m.sendStatus == SendStatus.sending)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x55000000),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
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
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xCC1A0E12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: const Color(0xFFE0564B), width: 1),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.refresh_rounded,
                                color: Color(0xFFE0564B), size: 16),
                            SizedBox(width: 5),
                            Text('Retry',
                                style: TextStyle(
                                    color: Color(0xFFE0564B),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
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
                    child: GlassPanel(
                      blur: 8,
                      radius: 12,
                      color: MilesColors.glass,
                      padding: const EdgeInsets.all(4),
                      child: SaveMediaButton(
                        size: 18,
                        onSave: () => SaveMediaService.savePhotoToVault(
                            url: url, senderName: senderName),
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
                style: TextStyle(color: MilesColors.cream50, fontSize: 14)),
          );
        }
        return _VoicePlayer(
            url: url, player: player, senderName: senderName);
      case 'video':
        return _VideoBubble(path: m.videoPath, senderName: senderName);
      default:
        return Text(
          m.body ?? '',
          style: TextStyle(
            color: textColor,
            fontSize: 15,
            height: 1.35,
          ),
        );
    }
  }
}

/// The themed chat background: a gradient/solid colour, or — for the 'custom'
/// theme — the user's photo with a dark scrim so message text stays readable.
class _ChatBg extends StatelessWidget {
  const _ChatBg({required this.theme, required this.bgUrl});
  final ChatTheme theme;
  final String? bgUrl;

  @override
  Widget build(BuildContext context) {
    if (theme.isCustom && bgUrl != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            bgUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: MilesColors.night),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: theme.bg.length == 1
              ? [theme.bg.first, theme.bg.first]
              : theme.bg,
        ),
      ),
    );
  }
}

class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer(
      {required this.url, required this.player, required this.senderName});
  final String url;
  final AudioPlayer player;
  final String senderName;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  bool _playing = false;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.player.playerStateStream.listen((state) {
      final playing =
          state.processingState != ProcessingState.completed && state.playing;
      if (playing != _playing) {
        if (mounted) setState(() => _playing = playing);
      }
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await widget.player.pause();
      } else {
        await widget.player.setUrl(widget.url);
        await widget.player.play();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play voice note.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: MilesColors.cream50.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
              url: widget.url, senderName: widget.senderName),
        ),
      ],
    );
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
                  style: TextStyle(color: MilesColors.cream50, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tap-to-play thumbnail for a private video message → full-screen player.
class _VideoBubble extends StatefulWidget {
  const _VideoBubble({required this.path, required this.senderName});
  final String? path;
  final String senderName;

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  bool _loading = false;

  Future<void> _open() async {
    if (widget.path == null) return;
    setState(() => _loading = true);
    final url = await ChatRepository.signedVideoUrl(widget.path);
    if (!mounted) return;
    setState(() => _loading = false);
    if (url == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Video unavailable')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => _FullScreenVideo(
              url: url, videoPath: widget.path, senderName: widget.senderName)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GestureDetector(
          onTap: _loading ? null : _open,
          child: Container(
            width: 220,
            height: 140,
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: _loading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Container(
                      padding: const EdgeInsets.all(10),
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: MilesColors.blush),
                      child: const Icon(Icons.play_arrow,
                          color: MilesColors.cream50, size: 30),
                    ),
            ),
          ),
        ),
        if (widget.path != null)
          Positioned(
            bottom: 6,
            right: 6,
            child: GlassPanel(
              blur: 8,
              radius: 12,
              color: MilesColors.glass,
              padding: const EdgeInsets.all(4),
              child: SaveMediaButton(
                size: 18,
                onSave: () => SaveMediaService.saveVideoToVault(
                    path: widget.path!, senderName: widget.senderName),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen player with FLAG_SECURE so intimate video can't be
/// screenshotted / screen-recorded / shown in the recents preview.
class _FullScreenVideo extends StatefulWidget {
  const _FullScreenVideo(
      {required this.url, this.videoPath, this.senderName = 'a message'});
  final String url;
  final String? videoPath;
  final String senderName;

  @override
  State<_FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<_FullScreenVideo> {
  VideoPlayerController? _vp;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _init();
  }

  Future<void> _init() async {
    final vp = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await vp.initialize();
    } catch (_) {
      await vp.dispose();
      return;
    }
    if (!mounted) {
      await vp.dispose();
      return;
    }
    setState(() {
      _vp = vp;
      _chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: true,
        looping: false,
        aspectRatio: vp.value.aspectRatio == 0 ? 16 / 9 : vp.value.aspectRatio,
      );
    });
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: const BackButton(color: Colors.white),
        actions: [
          if (widget.videoPath != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: SaveMediaButton(
                  size: 24,
                  color: Colors.white,
                  onSave: () => SaveMediaService.saveVideoToVault(
                      path: widget.videoPath!, senderName: widget.senderName),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: _chewie == null
            ? const CircularProgressIndicator()
            : Chewie(controller: _chewie!),
      ),
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
                style: Theme.of(context).textTheme.displaySmall),
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
