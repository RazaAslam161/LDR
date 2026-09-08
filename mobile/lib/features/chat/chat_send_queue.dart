import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_reactions.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_text_outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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

  /// How many times this has been attempted, and when the ladder next allows
  /// one. Both in memory only: a restored send starts its ladder again, which
  /// is right — the process died, so the network it failed on is long gone.
  int attempts = 0;
  DateTime? nextAttempt;
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

  int attempts = 0;
  DateTime? nextAttempt;
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
    // The socket opening is the most literal signal this app has for "the
    // network came back", and a queue that only retried on its own ladder
    // would sit out the first two minutes of a restored connection.
    realtimeResumed.addListener(kick);
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

  /// How many times a MEDIA send climbs the ladder before it stops and waits
  /// for a person. Six rungs is the table through 90 seconds — long enough to
  /// ride out a tunnel, short enough that a phone on a dead link is not still
  /// pushing the same video an hour later.
  static const _maxMediaAttempts = 6;

  final List<PendingSend> _pending = [];
  final List<PendingText> _text = [];

  /// Ids currently uploading, as opposed to merely accepted. Both look like
  /// [SendStatus.sending] to the chat — a queued item shows the same spinner —
  /// so the distinction cannot be read off the status.
  final Set<String> _inFlight = {};

  /// The same, for text — and a SEPARATE set on purpose.
  ///
  /// Sharing `_inFlight` would put text sends inside the upload cap, which is
  /// the one thing PendingText exists to stay out of: three messages typed in a
  /// row would then hold every slot and stop a photo uploading at all, and the
  /// row IS the send, so there is nothing here to bound.
  final Set<String> _textInFlight = {};

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

  /// The largest file Storage will actually take, with headroom.
  ///
  /// This org is on Supabase's FREE plan (`get_organization` → `"plan":"free"`),
  /// where the GLOBAL file size limit cannot exceed 50 MB and takes precedence
  /// over any bucket's own (storage/uploads/file-limits). `couple_intimate` is
  /// set to 100 MiB and that number is unreachable — the effective ceiling is
  /// the global one.
  ///
  /// Past it Storage answers 413, and [permanent] refuses to retry a 413 —
  /// correctly, because no number of attempts makes the file smaller. So an
  /// oversized video became a bubble that failed once, could never be made to
  /// send, and said nothing about why. Production, build 80:
  /// `chat-send DeliveryFailure "video n=1 gave-up storage.413"`.
  ///
  /// Nothing here shrinks a file — this app has no transcoder — so the honest
  /// move is to refuse it before it is a bubble and say so. The camera's own
  /// caps (rapid_camera_screen `_maxRecord`, PhotoPickerService `maxDuration`)
  /// are set so a recording made INSIDE the app can never reach this.
  static const int maxUploadBytes = 45 * 1024 * 1024;

  /// Whether [file] is past [maxUploadBytes] and cannot be sent.
  ///
  /// A file that cannot be measured is allowed through: the upload is the
  /// authority on what Storage accepts, and refusing on a failed stat would
  /// drop sends this ceiling was never about.
  static bool tooBig(File file) {
    try {
      return file.lengthSync() > maxUploadBytes;
    } on FileSystemException {
      return false;
    }
  }

  /// Accept a photo and start uploading. Returns immediately — the caller is
  /// expected to dismiss its screen on the next line.
  String enqueueImage(String coupleId, File file,
          {String? replyToId, String? id, String? caption,}) =>
      _enqueue(coupleId, file, 'image', replyToId, id, caption);

  String enqueueVideo(String coupleId, File file,
          {String? replyToId, String? id, String? caption,}) =>
      _enqueue(coupleId, file, 'video', replyToId, id, caption);

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
    String? caption,
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
    _sendCaption(coupleId, caption);
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
    String? caption,
  ) {
    final send = PendingSend(
      id: id ?? _uuid.v4(),
      coupleId: coupleId,
      file: file,
      kind: kind,
      replyToId: replyToId,
    );
    _pending.add(send);
    _sendCaption(coupleId, caption);
    _changed();
    _pump();
    return send.id;
  }

  /// What the sender typed under a picture goes as its own text message.
  ///
  /// Not as the media row's body, which is where it started: a build-73 phone
  /// never reads a body in the image or video arm, so the sentence decrypted
  /// there and was thrown away by every surface that build has — while the
  /// composer had already deleted the draft. Two handsets in the field run it
  /// and can never be made to update.
  ///
  /// A text row is the one shape both builds already render, and it inherits
  /// the whole durability path this queue just grew rather than needing its
  /// own.
  void _sendCaption(String coupleId, String? caption) {
    final body = caption?.trim() ?? '';
    if (body.isEmpty) return;
    enqueueText(coupleId, body);
  }

  /// Accept a text message and start inserting it.
  ///
  /// Text belongs here for the same reason media does: the send has to outlive
  /// the screen that started it. Moving off the chat tab disposes ChatScreen,
  /// and a failure arriving after that had nowhere to land — the optimistic
  /// bubble went with the widget and the message then existed nowhere at all.
  ///
  /// Persisted across a process kill, in [ChatTextOutbox] rather than in the
  /// prefs blob beside the media queue. The old reasoning here — that a body in
  /// plain SharedPreferences was worse than losing it — had the right objection
  /// and the wrong conclusion: the store the DRAFT of the same sentence already
  /// uses is encrypted at rest, so there was never a choice to make.
  ///
  /// "It lands in seconds or the sender is looking at a bubble they can retry"
  /// was also only true while the process lived. Android kills this app while
  /// it is backgrounded, and backgrounding is when the cover goes up.
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
    _keepBody(send.id, coupleId, body, replyToId);
    _changed();
    _pumpText();
    return send.id;
  }

  /// Put a body where a process kill cannot reach it. No-op for a null or
  /// empty one — a photo with no caption writes nothing.
  void _keepBody(
    String id,
    String coupleId,
    String body,
    String? replyToId, {
    bool failed = false,
  }) {
    if (body.isEmpty) return;
    final uid = _uid;
    if (uid == null) return;
    unawaited(ChatTextOutbox.put(id, {
      'id': id,
      'u': uid,
      'c': coupleId,
      'b': body,
      if (replyToId != null) 'r': replyToId,
      // The media half has always persisted this (`_persist`'s 'failed' key)
      // and the body half did not, so a send the ladder had permanently given
      // up on came back as `sending` on the next launch and ground against the
      // same refusal for the life of the install.
      if (failed) 'f': true,
      // A monotonic stamp, because the outbox is keyed by uuid and
      // `readAll()` hands its entries back in hash order — three messages
      // typed in a row came back shuffled and were then inserted in that
      // order. Never sent as created_at: the server stamps that, and the two
      // phones' clocks differ.
      'n': DateTime.now().microsecondsSinceEpoch,
    }));
  }

  /// The signed-in account, or null before the client has one.
  ///
  /// Guarded because `SupabaseService.client` is a `late final` that throws
  /// anywhere the app has not booted — and this singleton is built by whichever
  /// screen touches it first.
  static String? get _uid {
    try {
      return SupabaseService.currentUserId;
    } catch (_) {
      return null;
    }
  }

  /// Try a failed send again. No-op for anything already in flight.
  void retry(String id) {
    final send = _pending.where((s) => s.id == id).firstOrNull;
    if (send == null || send.status != SendStatus.failed) return;
    send.status = SendStatus.sending;
    // The person pressing Retry is a better signal than any ladder: their
    // network changed, or they know something the backoff does not.
    send.attempts = 0;
    send.nextAttempt = null;
    _changed();
    _pump();
  }

  /// Try a failed text again. No-op for anything already going.
  void retryText(String id) {
    final send = _text.where((s) => s.id == id).firstOrNull;
    if (send == null || send.status != SendStatus.failed) return;
    send.status = SendStatus.sending;
    send.attempts = 0;
    send.nextAttempt = null;
    _changed();
    _pumpText();
  }

  /// Give up on a failed send and forget it.
  void discard(String id) {
    _pending.removeWhere((s) => s.id == id && s.status == SendStatus.failed);
    unawaited(ChatTextOutbox.remove(id));
    _changed();
  }

  /// Give up on a failed text and forget it — including the stored body.
  ///
  /// Without it a message the ladder had permanently given up on could be
  /// deleted from the conversation and still come back on the next launch,
  /// because the only copy of it was the one on disk.
  void discardText(String id) {
    _text.removeWhere((s) => s.id == id && s.status == SendStatus.failed);
    unawaited(ChatTextOutbox.remove(id));
    _changed();
  }

  /// Whether a failed send with this id is the queue's to forget.
  bool holdsFailed(String id) =>
      _pending.any((s) => s.id == id && s.status == SendStatus.failed) ||
      _text.any((s) => s.id == id && s.status == SendStatus.failed);

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
    _inFlight.clear();
    _textInFlight.clear();
    _lastKick = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _restoredFor = null;
    // The bodies go with them, and this is the one place that rule differs
    // from ChatReactionOutbox's (which keeps its disk copy for the next
    // sign-in). This runs when the COUPLE ends, however it ended: a message
    // typed during the argument and left unsent must not be resurrected and
    // delivered to a couple the user has walked away from.
    unawaited(ChatTextOutbox.clearAll());
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
    await _restoreMedia();
    await _restoreText();
  }

  /// The media half — paths and ids, from SharedPreferences.
  ///
  /// Split out because the two halves were one method with an early `return`
  /// on a null prefs blob, and a text-only queue writes no prefs blob at all:
  /// the bodies were skipped on exactly the launch that had bodies to restore
  /// and no media. That is the whole feature, silently off.
  Future<void> _restoreMedia() async {
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
        //
        // Reported rather than dropped in silence. This is the queue losing a
        // photo the user believes they sent, and "the OS emptied the cache"
        // and "we wrote the wrong path" produce exactly the same nothing.
        if (!file.existsSync()) {
          ErrorReporter.report(
            DeliveryFailure(
              j['kind']?.toString() ?? 'media',
              attempt: 0,
              permanent: true,
              code: 'file.gone',
            ),
            StackTrace.current,
            kind: 'chat-send-restore',
          );
          unawaited(ChatTextOutbox.remove(j['id'] as String));
          continue;
        }
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
      if (restored.isNotEmpty) {
        // Ahead of anything accepted while this was reading: these are older.
        _pending.insertAll(0, restored);
        _changed();
        _pump();
      }
    } catch (e) {
      // This fleet is sideloaded and has no update channel, so a build will
      // meet shapes it did not write. Carry on sending rather than throw on
      // every launch.
      debugPrint('[send] restore failed: $e');
    }
  }

  /// Which account's bodies are already in memory. Null until one is, so a
  /// queue built before sign-in picks them up on the first [kick].
  String? _restoredFor;

  /// Bring back the bodies a previous process was still holding.
  ///
  /// Separate from [_restore] because it depends on there being a session:
  /// the outbox is scoped by user id, and this singleton is built by whichever
  /// screen touches it first — which on a cold start is before sign-in
  /// resolves. Re-run on every [kick] until it lands.
  Future<void> _restoreText() async {
    final uid = _uid;
    if (uid == null || _restoredFor == uid) return;
    _restoredFor = uid;
    final rows = await ChatTextOutbox.restore(uid);
    if (rows == null) {
      // The store could not be read. Unlatch, so the next kick tries again —
      // latching on a failure meant one transient read turned into bodies that
      // were never restored and were then deleted by the next sign-out.
      _restoredFor = null;
      return;
    }
    if (rows.isEmpty) return;
    // The outbox is keyed by uuid and `readAll()` returns its entries in hash
    // order, which is deterministic and has nothing to do with typing order.
    // Three messages written while offline came back shuffled and were then
    // inserted in that order — permanently, since the server stamps created_at
    // at insert time.
    rows.sort((a, b) => ((a['n'] as num?) ?? 0).compareTo((b['n'] as num?) ?? 0));
    var changed = false;
    for (final j in rows) {
      final id = j['id']?.toString();
      final body = j['b']?.toString();
      if (id == null || body == null || body.isEmpty) continue;
      if (_text.any((t) => t.id == id)) continue;
      _text.add(PendingText(
        id: id,
        coupleId: j['c']?.toString() ?? '',
        body: body,
        replyToId: j['r']?.toString(),
        // Carried across the restart, as the media half always has. Without
        // it a send the ladder had permanently given up on came back as
        // `sending` and ground against the same refusal on every launch.
        status: j['f'] == true ? SendStatus.failed : SendStatus.sending,
      ));
      changed = true;
    }
    if (!changed) return;
    _changed();
    _pumpText();
  }


  /// Start as many accepted sends as the cap allows, oldest first.
  void _pump() {
    final now = DateTime.now();
    for (final send in _pending) {
      if (_inFlight.length >= _maxInFlight) return;
      if (send.status != SendStatus.sending || _inFlight.contains(send.id)) {
        continue;
      }
      // Waiting out its backoff. It still reads as `sending` to the chat,
      // which is the truth: nothing has been given up on.
      if (send.nextAttempt?.isAfter(now) ?? false) continue;
      _inFlight.add(send.id);
      unawaited(_run(send));
    }
    _arm();
  }

  /// The same, for text. No cap: there is no upload here, so a text send does
  /// not compete for the [_maxInFlight] slots a photo needs.
  void _pumpText() {
    final now = DateTime.now();
    for (final send in _text) {
      if (send.status != SendStatus.sending ||
          _textInFlight.contains(send.id)) {
        continue;
      }
      if (send.nextAttempt?.isAfter(now) ?? false) continue;
      _textInFlight.add(send.id);
      unawaited(_runText(send));
    }
    _arm();
  }

  Future<void> _run(PendingSend send) async {
    try {
      await (uploader ?? _upload)(send);
      // Landed. The DB echo carries the same id, so the chat reconciles the
      // optimistic bubble rather than showing it twice.
      _pending.removeWhere((s) => s.id == send.id);
      unawaited(ChatTextOutbox.remove(send.id));
      _changed();
    } catch (e) {
      // Capped, unlike text. Every rung re-runs the WHOLE send — the upload
      // included, under a fresh random object name — so an unbounded ladder on
      // a 40 MB video is that video going up the phone's metered link again at
      // 1s, 3s, 8s, 20s, 45s, 90s and then every three minutes for as long as
      // the app lives, each attempt orphaning another object in the couple's
      // bucket. Text has no such cost and keeps trying forever.
      //
      // Reaching the cap is also what gives the person a way out: `failed` is
      // what makes the bubble selectable and its Retry chip appear, and while
      // it reads `sending` there is no gesture anywhere that can stop it.
      final n = ++send.attempts;
      _afterFailure(send.kind, send.id, e, n, (gaveUp) {
        send.status = gaveUp ? SendStatus.failed : SendStatus.sending;
        send.nextAttempt =
            gaveUp ? null : DateTime.now().add(ChatReactionOutbox.backoffFor(n));
      }, capped: n >= _maxMediaAttempts,);
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
      unawaited(ChatTextOutbox.remove(send.id));
    } catch (e) {
      _afterFailure('text', send.id, e, ++send.attempts, (gaveUp) {
        send.status = gaveUp ? SendStatus.failed : SendStatus.sending;
        send.nextAttempt = gaveUp
            ? null
            : DateTime.now().add(ChatReactionOutbox.backoffFor(send.attempts));
        // Disk has to agree with memory, or the next launch resurrects it.
        if (gaveUp) {
          _keepBody(send.id, send.coupleId, send.body, send.replyToId,
              failed: true,);
        }
      });
    } finally {
      _textInFlight.remove(send.id);
      _changed();
      _pumpText();
    }
  }

  /// Classify one failure, record it, and let the caller park or re-arm.
  ///
  /// Every failure used to go straight to `failed` — and to `debugPrint`,
  /// which is inert in a release build. So one dead second of network left a
  /// message sitting there wearing a retry button nobody was in the room to
  /// press, and no record that it had ever been attempted. A send now stops
  /// trying only when trying could not possibly help.
  void _afterFailure(
    String what,
    String id,
    Object e,
    int attempts,
    void Function(bool gaveUp) settle, {
    bool capped = false,
  }) {
    final gaveUp = permanent(e) || capped;
    settle(gaveUp);
    debugPrint('[send] $what $id attempt $attempts: ${e.runtimeType}'
        '${gaveUp ? ' (gave up)' : ''}');
    // The first failure and the giving-up, never every rung: a queue grinding
    // against a dead network must not spend the run's whole report budget
    // saying so.
    if (attempts != 1 && !gaveUp) return;
    ErrorReporter.report(
      DeliveryFailure(
        what,
        attempt: attempts,
        permanent: gaveUp,
        code: _codeOf(e),
      ),
      StackTrace.current,
      kind: 'chat-send',
    );
  }

  static String? _codeOf(Object e) => switch (e) {
        PostgrestException(:final code) => code,
        StorageException(:final statusCode) => 'storage.$statusCode',
        _ => null,
      };

  /// Whether retrying could ever help.
  ///
  /// Postgrest is classified by [ChatReactionOutbox.permanent] rather than by a
  /// second copy of the same table: a reaction and a message that will not land
  /// are the same outage, and two classifiers would drift apart.
  ///
  /// Storage is this queue's alone, because a reaction never uploads anything.
  /// Both of its refusals are final — 413 means the file is bigger than the
  /// bucket will ever accept, and 403 is an RLS decision, including the one a
  /// full account produces (which StorageQuota.explain is what puts into
  /// words). Climbing a ladder against either is a spinner that never resolves.
  @visibleForTesting
  static bool permanent(Object e) {
    if (e is StorageException) {
      return e.statusCode == '413' || e.statusCode == '403';
    }
    return ChatReactionOutbox.permanent(e);
  }

  Timer? _retryTimer;

  /// When the last [kick] collapsed the ladder. A flapping socket ticks
  /// [realtimeResumed] repeatedly and unpaced, and without a floor every tick
  /// would fire each parked send at a connection that is still broken.
  DateTime? _lastKick;

  /// The network probably just came back — try everything again, now.
  ///
  /// Called on app resume and on every socket open, and deliberately more
  /// aggressive than the ladder: someone who has just opened the app expects
  /// the message they sent an hour ago to go now, not at the next rung.
  void kick() {
    unawaited(_restoreText());
    final now = DateTime.now();
    if (_lastKick != null &&
        now.difference(_lastKick!) < const Duration(seconds: 3)) {
      return;
    }
    _lastKick = now;
    for (final s in _pending) {
      if (s.status == SendStatus.sending) s.nextAttempt = null;
    }
    for (final s in _text) {
      if (s.status == SendStatus.sending) s.nextAttempt = null;
    }
    _pump();
    _pumpText();
  }

  /// One timer for the whole queue, set to the soonest rung.
  void _arm() {
    _retryTimer?.cancel();
    _retryTimer = null;
    DateTime? soonest;
    for (final at in [
      for (final s in _pending)
        if (s.status == SendStatus.sending) s.nextAttempt,
      for (final s in _text)
        if (s.status == SendStatus.sending) s.nextAttempt,
    ]) {
      if (at == null) continue;
      if (soonest == null || at.isBefore(soonest)) soonest = at;
    }
    if (soonest == null) return;
    final wait = soonest.difference(DateTime.now());
    _retryTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _pump();
      _pumpText();
    });
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
