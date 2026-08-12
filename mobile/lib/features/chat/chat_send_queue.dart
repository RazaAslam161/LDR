import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:uuid/uuid.dart';

/// One upload+insert — the real one, or a fake in a test.
typedef SendOne = Future<void> Function(PendingSend send);

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
  ChatSendQueue._();
  static final ChatSendQueue instance = ChatSendQueue._();

  static const _uuid = Uuid();

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

  /// Ids currently uploading, as opposed to merely accepted. Both look like
  /// [SendStatus.sending] to the chat — a queued item shows the same spinner —
  /// so the distinction cannot be read off the status.
  final Set<String> _inFlight = {};

  /// The upload itself. Swappable because nothing that matters here — the cap,
  /// one item failing without touching the others — is observable through a
  /// path that can only ever fail (no Supabase) or only ever succeed.
  @visibleForTesting
  SendOne? uploader;

  /// Sends still in flight or failed, oldest first.
  List<PendingSend> get pending => List.unmodifiable(_pending);

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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
    _pump();
    return send.id;
  }

  /// Try a failed send again. No-op for anything already in flight.
  void retry(String id) {
    final send = _pending.where((s) => s.id == id).firstOrNull;
    if (send == null || send.status != SendStatus.failed) return;
    send.status = SendStatus.sending;
    notifyListeners();
    _pump();
  }

  /// Give up on a failed send and forget it.
  void discard(String id) {
    _pending.removeWhere((s) => s.id == id && s.status == SendStatus.failed);
    notifyListeners();
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
    notifyListeners();
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
      notifyListeners();
    } catch (e) {
      debugPrint('[send] ${send.kind} ${send.id} failed: $e');
      // Kept, not dropped: a failed photo used to disappear with no way to try
      // again. It stays in the list as failed so the chat can offer a retry.
      // One item failing is one item — the rest of a batch keeps going.
      send.status = SendStatus.failed;
      notifyListeners();
    } finally {
      _inFlight.remove(send.id);
      // A slot just freed up; the next item in the batch takes it.
      _pump();
    }
  }

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
