import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:uuid/uuid.dart';

/// A send that has been accepted from the user but has not landed yet.
class PendingSend {
  PendingSend({
    required this.id,
    required this.coupleId,
    required this.file,
    required this.kind,
    this.replyToId,
    this.status = SendStatus.sending,
  });

  final String id;
  final String coupleId;
  final File file;

  /// 'image' or 'video'. Voice notes still go straight through the repository —
  /// they are recorded in the chat, where the user is already looking at the
  /// bubble.
  final String kind;
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
  ChatSendQueue._();
  static final ChatSendQueue instance = ChatSendQueue._();

  static const _uuid = Uuid();

  final List<PendingSend> _pending = [];

  /// Sends still in flight or failed, oldest first.
  List<PendingSend> get pending => List.unmodifiable(_pending);

  /// Accept a photo and start uploading. Returns immediately — the caller is
  /// expected to dismiss its screen on the next line.
  String enqueueImage(String coupleId, File file, {String? replyToId, String? id}) =>
      _enqueue(coupleId, file, 'image', replyToId, id);

  String enqueueVideo(String coupleId, File file, {String? replyToId}) =>
      _enqueue(coupleId, file, 'video', replyToId, null);

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
    unawaited(_run(send));
    return send.id;
  }

  /// Try a failed send again. No-op for anything already in flight.
  void retry(String id) {
    final send = _pending.where((s) => s.id == id).firstOrNull;
    if (send == null || send.status != SendStatus.failed) return;
    send.status = SendStatus.sending;
    notifyListeners();
    unawaited(_run(send));
  }

  /// Give up on a failed send and forget it.
  void discard(String id) {
    _pending.removeWhere((s) => s.id == id && s.status == SendStatus.failed);
    notifyListeners();
  }

  Future<void> _run(PendingSend send) async {
    try {
      if (send.kind == 'video') {
        await ChatRepository.sendVideo(send.coupleId, send.file,
            replyToId: send.replyToId,);
      } else {
        final path = await ChatRepository.sendImage(
          send.coupleId,
          send.file,
          id: send.id,
          replyToId: send.replyToId,
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
      // Landed. The DB echo carries the same id, so the chat reconciles the
      // optimistic bubble rather than showing it twice.
      _pending.removeWhere((s) => s.id == send.id);
      notifyListeners();
    } catch (e) {
      debugPrint('[send] ${send.kind} ${send.id} failed: $e');
      // Kept, not dropped: a failed photo used to disappear with no way to try
      // again. It stays in the list as failed so the chat can offer a retry.
      send.status = SendStatus.failed;
      notifyListeners();
    }
  }
}
