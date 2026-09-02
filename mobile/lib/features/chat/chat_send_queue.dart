import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// One upload+insert — the real one, or a fake in a test.
typedef SendOne = Future<void> Function(PendingSend send);

/// One text insert — the real one, or a fake in a test.
typedef SendText = Future<void> Function(PendingText send);

/// A send that has been accepted from the user but has not landed yet.
class PendingSend {
  PendingSend({
    required this.id,
    required this.coupleId,
    required this.file,
    required this.kind,
    this.replyToId,
    this.fileName,
    this.albumId,
    this.status = SendStatus.sending,
  });

  final String id;
  final String coupleId;
  final File file;

  /// The pick this item came from, shared by every item in it.
  ///
  /// Minted here rather than derived later from timestamps because the upload
  /// order is not the pick order and the spread is not small: [_maxInFlight]
  /// items move at a time, so a pick of twelve photos and one long video has
  /// the video landing a minute after the first photo. Any time window loose
  /// enough to hold that together also swallows whatever was sent next.
  final String? albumId;

  /// 'image', 'video' or 'file'. Voice notes still go straight through the
  /// repository — they are recorded in the chat, where the user is already
  /// looking at the bubble.
  final String kind;
  final String? replyToId;

  /// What a document is called. Set for kind 'file' and null otherwise: the
  /// document provider caches under a name of its own, so the path cannot be
  /// asked afterwards.
  final String? fileName;

  SendStatus status;
}

/// A text message that has been accepted from the user but has not landed yet.
///
/// Its own type rather than a [PendingSend] with a null file: there is no
/// upload here, so it does not compete for the [ChatSendQueue._maxInFlight]
/// slots a photo needs — the row IS the send.
class PendingText {
  PendingText({
    required this.id,
    required this.coupleId,
    required this.body,
    this.replyToId,
    this.status = SendStatus.sending,
  });

  final String id;
  final String coupleId;
  final String body;
  final String? replyToId;

  SendStatus status;
}

/// Owns media sends from the moment the user commits to them.
///
/// The user should never wait on an upload. Every camera in this app used to
/// park behind a full-screen "sending" veil until the bytes were in Supabase
/// and a row was inserted — on a bad connection that is the app freezing on
/// them for as long as their network feels like taking.
///
/// This exists as a singleton rather than living in ChatScreen because the
/// camera can be opened from the shell with the chat NOT mounted (AppShell's
/// camera tab). The send has to survive the screen that started it, and the
/// chat has to be able to pick up sends it never saw begin — so the pending
/// list belongs to neither widget.
class ChatSendQueue extends ChangeNotifier {
  ChatSendQueue._() {
    // Restored from the constructor rather than from app start-up: this is a
    // lazily built singleton, so its construction is the first moment anything
    // can observe the queue at all — whichever screen sends or watches first.
    unawaited(_restore());
  }
  static final ChatSendQueue instance = ChatSendQueue._();

  static const _uuid = Uuid();

  /// Where accepted media survives the process.
  ///
  /// Android kills this app while it is backgrounded, and backgrounding is when
  /// the disguise cover goes up — so it is the ordinary case here, not a rare
  /// one. A list that lived only in memory took every queued photo with it: no
  /// row, no file reference, and nothing left on screen to retry.
  ///
  /// Ids, a local path, a kind. Nothing is written here that is not already
  /// either on this phone's filesystem or bound for the row the send is about
  /// to insert — message bodies in particular are not (see [enqueueText]).
  static const _storeKey = 'chat_send_queue';

  /// How many uploads actually move at once.
  ///
  /// A 50-item gallery pick is the case this bounds. Firing all 50 puts fifty
  /// TLS handshakes and fifty bodies on one phone uplink: every one of them
  /// crawls, so the FIRST photo lands about as late as the fiftieth and the
  /// chat looks frozen. Serial is the other failure — item 50 waits on 49
  /// uploads. A few at a time keeps the link saturated and lets the early
  /// bubbles resolve while the rest queue.
  static const _maxInFlight = 3;

  final List<PendingSend> _pending = [];
  final List<PendingText> _text = [];

  /// Ids currently uploading, as opposed to merely accepted. Both look like
  /// [SendStatus.sending] to the chat — a queued item shows the same spinner —
  /// so the distinction cannot be read off the status.
  final Set<String> _inFlight = {};

  /// The upload itself. Swappable because nothing that matters here — the cap,
  /// one item failing without touching the others — is observable through a
  /// path that can only ever fail (no Supabase) or only ever succeed.
  @visibleForTesting
  SendOne? uploader;

  /// The text insert, swappable for the same reason as [uploader].
  @visibleForTesting
  SendText? textSender;

  /// Sends still in flight or failed, oldest first.
  List<PendingSend> get pending => List.unmodifiable(_pending);

  /// Text sends still in flight or failed, oldest first.
  List<PendingText> get pendingText => List.unmodifiable(_text);

  /// Accept a photo and start uploading. Returns immediately — the caller is
  /// expected to dismiss its screen on the next line.
  String enqueueImage(String coupleId, File file,
          {String? replyToId, String? id,}) =>
      _enqueue(coupleId, file, 'image', replyToId, id);

  String enqueueVideo(String coupleId, File file, {String? replyToId}) =>
      _enqueue(coupleId, file, 'video', replyToId, null);

  /// Accept a whole document pick at once, in the order it was picked.
  List<String> enqueueFiles(
    String coupleId,
    List<({File file, String name})> docs, {
    String? replyToId,
  }) {
    final ids = <String>[];
    for (final (i, doc) in docs.indexed) {
      final send = PendingSend(
        id: _uuid.v4(),
        coupleId: coupleId,
        file: doc.file,
        kind: 'file',
        fileName: doc.name,
        replyToId: i == 0 ? replyToId : null,
      );
      _pending.add(send);
      ids.add(send.id);
    }
    _changed();
    _pump();
    return ids;
  }

  /// Accept a whole gallery pick at once, in the order it was picked.
  ///
  /// Every item is pending — and so already a bubble — before a single byte
  /// moves; [_maxInFlight] of them upload at a time. Listeners are told once
  /// rather than once per item, so 50 photos are one rebuild of the chat and
  /// not fifty.
  List<String> enqueueAll(
    String coupleId,
    List<({File file, bool isVideo})> items, {
    String? replyToId,
  }) {
    final ids = <String>[];
    // One id for the whole pick, and only when there is actually a group to
    // name: a single photo is not an album, and stamping it as one would make
    // the list build a one-tile grid instead of the photo bubble it should be.
    final albumId = items.length > 1 ? _uuid.v4() : null;
    for (final (i, item) in items.indexed) {
      final send = PendingSend(
        id: _uuid.v4(),
        coupleId: coupleId,
        file: item.file,
        kind: item.isVideo ? 'video' : 'image',
        // The reply belongs to the first item only. Twelve photos each quoting
        // the same message is twelve copies of it down the conversation.
        replyToId: i == 0 ? replyToId : null,
        albumId: albumId,
      );
      _pending.add(send);
      ids.add(send.id);
    }
    _changed();
    _pump();
    return ids;
  }

  String _enqueue(
    String coupleId,
    File file,
    String kind,
    String? replyToId,
    String? id,
  ) {
    final send = PendingSend(
      id: id ?? _uuid.v4(),
      coupleId: coupleId,
      file: file,
      kind: kind,
      replyToId: replyToId,
    );
    _pending.add(send);
    _changed();
    _pump();
    return send.id;
  }

  /// Accept a text message and start inserting it.
  ///
  /// Text belongs here for the same reason media does: the send has to outlive
  /// the screen that started it. Moving off the chat tab disposes ChatScreen,
  /// and a failure arriving after that had nowhere to land — the optimistic
  /// bubble went with the widget and the message then existed nowhere at all.
  ///
  /// Deliberately NOT persisted across a process kill, unlike [_pending]: the
  /// bodies would sit in plain SharedPreferences, which is the one place the
  /// app's disguise cannot cover. A text send is a single insert — it lands in
  /// seconds or the sender is looking at a bubble they can retry.
  String enqueueText(
    String coupleId,
    String body, {
    String? replyToId,
    String? id,
  }) {
    final send = PendingText(
      id: id ?? _uuid.v4(),
      coupleId: coupleId,
      body: body,
      replyToId: replyToId,
    );
    _text.add(send);
    _changed();
    unawaited(_runText(send));
    return send.id;
  }

  /// Try a failed send again. No-op for anything already in flight.
  void retry(String id) {
    final send = _pending.where((s) => s.id == id).firstOrNull;
    if (send == null || send.status != SendStatus.failed) return;
    send.status = SendStatus.sending;
    _changed();
    _pump();
  }

  /// Try a failed text again. No-op for anything already going.
  void retryText(String id) {
    final send = _text.where((s) => s.id == id).firstOrNull;
    if (send == null || send.status != SendStatus.failed) return;
    send.status = SendStatus.sending;
    _changed();
    unawaited(_runText(send));
  }

  /// Give up on a failed send and forget it.
  void discard(String id) {
    _pending.removeWhere((s) => s.id == id && s.status == SendStatus.failed);
    _changed();
  }

  /// Drop everything on sign-out.
  ///
  /// This queue is a process singleton and outlives the session that filled
  /// it. A send accepted for one couple would otherwise still be retried under
  /// the next account signed in on the handset — refused by RLS, but it is
  /// that account's network and that account's battery, and the file is
  /// somebody else's.
  void clear() {
    _pending.clear();
    _text.clear();
    _changed();
  }

  /// Every mutation ends here: the stored copy is written on the same call that
  /// tells the listeners, so what survives a kill cannot drift from what the
  /// chat is showing.
  void _changed() {
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The list is read AFTER the await, never captured before it: two
      // overlapping writes then both carry the newest state, so whichever
      // reaches the platform last is still the truth.
      if (_pending.isEmpty) {
        await prefs.remove(_storeKey);
        return;
      }
      await prefs.setString(
        _storeKey,
        jsonEncode([
          for (final s in _pending)
            {
              'id': s.id,
              'couple': s.coupleId,
              'path': s.file.path,
              'kind': s.kind,
              if (s.replyToId != null) 'reply': s.replyToId,
              if (s.fileName != null) 'name': s.fileName,
              if (s.albumId != null) 'album': s.albumId,
              if (s.status == SendStatus.failed) 'failed': true,
            },
        ]),
      );
    } catch (e) {
      // A backup that cannot be written must not take the send with it: the
      // upload this was backing is still perfectly fine, and unhandled the
      // throw would surface through main.dart's platformDispatcher handler.
      debugPrint('[send] persist failed: $e');
    }
  }

  /// Bring back whatever the previous process was still holding.
  ///
  /// Restored sends keep their id, so one that actually landed just before the
  /// kill reconciles against its own row instead of arriving twice.
  Future<void> _restore() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_storeKey);
      if (raw == null) return;
      final restored = <PendingSend>[];
      for (final j
          in (jsonDecode(raw) as List).whereType<Map<String, dynamic>>()) {
        final file = File(j['path'] as String);
        // The temp directory is the OS's to empty whenever it likes. A send
        // whose file is gone can only ever fail, and a bubble offering a retry
        // that cannot work is worse than the send being gone.
        if (!file.existsSync()) continue;
        restored.add(PendingSend(
          id: j['id'] as String,
          coupleId: j['couple'] as String,
          file: file,
          kind: j['kind'] as String,
          replyToId: j['reply'] as String?,
          fileName: j['name'] as String?,
          albumId: j['album'] as String?,
          status: j['failed'] == true ? SendStatus.failed : SendStatus.sending,
        ),);
      }
      if (restored.isEmpty) return;
      // Ahead of anything accepted while this was reading: these are older.
      _pending.insertAll(0, restored);
      _changed();
      _pump();
    } catch (e) {
      // This fleet is sideloaded and has no update channel, so a build will
      // meet shapes it did not write. Carry on sending rather than throw on
      // every launch.
      debugPrint('[send] restore failed: $e');
    }
  }

  /// Start as many accepted sends as the cap allows, oldest first.
  void _pump() {
    for (final send in _pending) {
      if (_inFlight.length >= _maxInFlight) return;
      if (send.status != SendStatus.sending || _inFlight.contains(send.id)) {
        continue;
      }
      _inFlight.add(send.id);
      unawaited(_run(send));
    }
  }

  Future<void> _run(PendingSend send) async {
    try {
      await (uploader ?? _upload)(send);
      // Landed. The DB echo carries the same id, so the chat reconciles the
      // optimistic bubble rather than showing it twice.
      _pending.removeWhere((s) => s.id == send.id);
      _changed();
    } catch (e) {
      debugPrint('[send] ${send.kind} ${send.id} failed: $e');
      // Kept, not dropped: a failed photo used to disappear with no way to try
      // again. It stays in the list as failed so the chat can offer a retry.
      // One item failing is one item — the rest of a batch keeps going.
      send.status = SendStatus.failed;
      _changed();
    } finally {
      _inFlight.remove(send.id);
      // A slot just freed up; the next item in the batch takes it.
      _pump();
    }
  }

  Future<void> _runText(PendingText send) async {
    try {
      await (textSender ?? _sendText)(send);
      // Landed. The DB echo carries the same id, so the chat reconciles the
      // optimistic bubble rather than showing it twice.
      _text.removeWhere((s) => s.id == send.id);
    } catch (e) {
      debugPrint('[send] text ${send.id} failed: $e');
      // Kept, not dropped: the input bar cleared the moment the user pressed
      // send, so this body is the only copy of the message left anywhere.
      send.status = SendStatus.failed;
    }
    _changed();
  }

  static Future<void> _sendText(PendingText send) => ChatRepository.sendText(
        send.coupleId,
        send.body,
        id: send.id,
        replyToId: send.replyToId,
      );

  static Future<void> _upload(PendingSend send) async {
    if (send.kind == 'file') {
      await ChatRepository.sendFile(
          send.coupleId, send.file, send.fileName ?? 'file',
          id: send.id, replyToId: send.replyToId,);
      return;
    }
    if (send.kind == 'video') {
      await ChatRepository.sendVideo(send.coupleId, send.file,
          id: send.id, replyToId: send.replyToId, albumId: send.albumId,);
      return;
    }
    final path = await ChatRepository.sendImage(
      send.coupleId,
      send.file,
      id: send.id,
      replyToId: send.replyToId,
      albumId: send.albumId,
    );
    // Fast-path the photo to the partner's chat if it happens to be open.
    final myUid = SupabaseService.currentUserId;
    if (path != null && myUid != null) {
      ChatBroadcastService.broadcastImage(
        id: send.id,
        senderId: myUid,
        imagePath: path,
        replyToId: send.replyToId,
      );
    }
  }
}
