import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One person's reaction to one message, as a screen holds it.
///
/// The two identifiers are the keys of the map this lives in, so they are not
/// repeated here — a copy of an id that can drift from the key it is stored
/// under is a bug waiting for a rename.
@immutable
class ChatReaction {
  const ChatReaction({required this.emoji, required this.at});

  final String emoji;

  /// When the person who owns this reaction last changed it — the server's
  /// `updated_at`, or the sender's own clock on the broadcast path.
  ///
  /// Load-bearing, not decoration. Add, remove and add again inside a second
  /// puts three events on two wires that do not preserve order between them,
  /// and this is what settles which one is current. It orders one person's
  /// events against themselves only, so the two devices' clocks never have to
  /// agree.
  final DateTime at;
}

/// messageId → userId → that person's reaction.
typedef ReactionsByMessage = Map<String, Map<String, ChatReaction>>;

/// A sealed emoji, ready for both wires: the durable column and the broadcast.
@immutable
class SealedReaction {
  const SealedReaction({
    required this.emoji,
    required this.cipher,
    required this.nonce,
    required this.at,
  });

  /// Kept in memory only. It is what the screen paints, and what a restored
  /// outbox has to recover by decrypting — it is never written to disk in this
  /// form, the same line ChatSendQueue holds for message bodies.
  final String emoji;
  final Uint8List cipher;
  final Uint8List nonce;
  final DateTime at;
}

/// Reading and writing `message_reactions`.
///
/// The emoji is content — it records what one partner felt about one message —
/// so it is sealed under the couple key exactly like a message body, on the
/// durable column AND on the live broadcast. There is deliberately no plaintext
/// column beside the ciphertext: bodies need one only because every client
/// already in the field reads `body`, and no client has ever read this table.
class ChatReactionRepository {
  ChatReactionRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static const table = 'message_reactions';

  /// The six on the bar, in the order they are drawn.
  ///
  /// The set WhatsApp and iMessage both settled on, and every one of them is
  /// neutral: this app writes no suggestive copy of its own, and an emoji the
  /// APP puts in front of someone is app-authored copy.
  static const quick = <String>['❤️', '😂', '😮', '😢', '🙏', '👍'];

  /// How many message ids go in one PostgREST `in` filter.
  ///
  /// A uuid costs ~38 characters of query string, so a page of 300 messages
  /// asked for in one request builds an 11 KB URL — past what proxies accept.
  /// The chunks go out together, so this costs requests and not latency.
  static const _idsPerRequest = 100;

  /// The associated data both halves of a reaction cipher must agree on.
  ///
  /// One function rather than the two ids written out twice: a divergence
  /// between the sealer and the opener does not fail loudly, it makes every
  /// reaction written after it permanently unreadable on a fleet with no update
  /// channel. It binds the message AND the person, so a blob cannot be replayed
  /// onto another message or attributed to the other partner.
  @visibleForTesting
  static String reactionAd(String messageId, String userId) =>
      '$messageId:$userId';

  /// Seals [emoji] for both wires. Null when this device has no couple key —
  /// which the caller must treat as "not written", never as "written in the
  /// clear".
  static Future<SealedReaction?> seal({
    required String emoji,
    required String messageId,
    required String userId,
    required DateTime at,
  }) async {
    try {
      // Join the derive the session started rather than racing it, the same way
      // sealBody does — otherwise whether a reaction seals depends on how long
      // the user has been in the app.
      await CoupleKey.ready();
      final p = await CryptoCore.encryptString(
        _pad(emoji),
        associatedData: reactionAd(messageId, userId),
      );
      final nonce = base64Decode(p.nonceB64);
      final blob = packMacAndCiphertext(p);
      // The same refusal sealBody makes: an all-zero nonce or MAC is
      // CryptoCore's retired plaintext sentinel, and storing that in a column
      // named `emoji_cipher` would move cleartext into the encrypted column and
      // call it encrypted. The layout is mac(16)||ciphertext, so the MAC is the
      // first 16 bytes.
      if (nonce.every((b) => b == 0) || blob.take(16).every((b) => b == 0)) {
        debugPrint('[reactions] refusing to store an unencrypted emoji');
        return null;
      }
      return SealedReaction(emoji: emoji, cipher: blob, nonce: nonce, at: at);
    } catch (e) {
      // Debug only: a couple with no key hits this on every tap, and debugPrint
      // is not stripped from a release build. The release-visible record is the
      // diag event the outbox writes for every attempt.
      if (kDebugMode) {
        debugPrint('[reactions] not sealed: ${e.runtimeType}');
      }
      return null;
    }
  }

  /// Opens one sealed emoji. Null when it cannot be read — a value the caller
  /// renders as nothing at all rather than as an empty reaction.
  static Future<String?> open({
    required Uint8List cipher,
    required Uint8List nonce,
    required String messageId,
    required String userId,
  }) async {
    try {
      await CoupleKey.ready();
      return _unpad(await CryptoCore.decryptString(
        unpackMacAndCiphertext(blob: cipher, nonce: nonce),
        associatedData: reactionAd(messageId, userId),
      ),);
    } catch (_) {
      return null;
    }
  }

  /// Every sealed emoji is the same width.
  ///
  /// XChaCha20 is a stream cipher and nothing on this path pads, so an unpadded
  /// blob is exactly 16 + the emoji's UTF-8 length. Across the 72-glyph palette
  /// this app itself defines that is three buckets — and ❤️, at six bytes where
  /// the other five on the bar are four, sits alone in its own. Storing the
  /// length of a value drawn from a closed set the reader also has is storing
  /// the value; `octet_length(emoji_cipher)` would have said "she sent a heart"
  /// to anyone holding the database.
  ///
  /// Both wires get it, because both carry these bytes.
  static const _sealedBytes = 32;

  /// NUL is safe filler: no UTF-8 encoding of an emoji contains a zero byte.
  ///
  /// Throws rather than degrading, so an over-long value is a reaction that
  /// visibly did not send instead of one that quietly leaks its length. The
  /// app's own palette tops out at six bytes; the sealer's catch turns this
  /// into the same "couldn't send that reaction" the no-key path shows.
  static String _pad(String emoji) {
    final n = utf8.encode(emoji).length;
    if (n > _sealedBytes) {
      throw ArgumentError('reaction is $n bytes, over the seal width');
    }
    // Escaped, never a literal control character: a raw NUL in the source
    // makes git treat the whole file as BINARY, so it commits with no
    // reviewable diff.
    return emoji + '\u0000' * (_sealedBytes - n);
  }

  static String _unpad(String padded) {
    var end = padded.length;
    while (end > 0 && padded.codeUnitAt(end - 1) == 0) {
      end--;
    }
    return padded.substring(0, end);
  }

  /// Every reaction on [messageIds], opened.
  ///
  /// Shortfalls are counted and surfaced rather than silently thinning the
  /// result: a page that comes back with fewer reactions than rows is a finding
  /// about this device's key, not a conversation nobody reacted to.
  static Future<ReactionsByMessage> fetchFor(
    String coupleId,
    Iterable<String> messageIds,
  ) async {
    final ids = messageIds.toSet().toList();
    if (ids.isEmpty) return {};

    final chunks = <List<String>>[];
    for (var i = 0; i < ids.length; i += _idsPerRequest) {
      final end = i + _idsPerRequest;
      chunks.add(ids.sublist(i, end > ids.length ? ids.length : end));
    }

    final pages = await Future.wait(
      chunks.map((chunk) => _c
          .from(table)
          .select('message_id,user_id,emoji_cipher,emoji_nonce,updated_at')
          // RLS already scopes this to the couple. The predicate is here for
          // the index, which leads on couple_id.
          .eq('couple_id', coupleId)
          .inFilter('message_id', chunk),),
    );

    final rows = pages.expand((p) => p).toList();
    final out = <String, Map<String, ChatReaction>>{};
    var failed = 0;
    for (final row in rows) {
      final messageId = row['message_id']?.toString();
      final userId = row['user_id']?.toString();
      if (messageId == null || userId == null) {
        failed++;
        continue;
      }
      Uint8List cipher;
      Uint8List nonce;
      try {
        cipher = byteaToBytes(row['emoji_cipher']);
        nonce = byteaToBytes(row['emoji_nonce']);
      } catch (_) {
        failed++;
        continue;
      }
      final emoji = await open(
        cipher: cipher,
        nonce: nonce,
        messageId: messageId,
        userId: userId,
      );
      if (emoji == null) {
        failed++;
        continue;
      }
      out.putIfAbsent(messageId, () => {})[userId] = ChatReaction(
        emoji: emoji,
        at: DateTime.tryParse(row['updated_at']?.toString() ?? '')?.toLocal() ??
            DateTime.now(),
      );
    }
    if (failed > 0) {
      // The CLASS of the shortfall only — the value is one person's reaction to
      // one message, and this is an E2EE app.
      ErrorReporter.report(
        ParseShortfall('chat reactions',
            parsed: rows.length - failed,
            of: rows.length,
            first: 'unreadable reaction',),
        StackTrace.current,
        kind: 'reaction-decrypt',
      );
    }
    return out;
  }

  /// Writes (or overwrites) one person's reaction to one message.
  ///
  /// An upsert, not an insert: changing your mind is an UPDATE of the one row
  /// the primary key allows you, so this is the same call whether or not you
  /// have reacted to this message before.
  static Future<void> put({
    required String coupleId,
    required String messageId,
    required String userId,
    required Uint8List cipher,
    required Uint8List nonce,
    required DateTime at,
  }) =>
      _c.from(table).upsert({
        'message_id': messageId,
        'user_id': userId,
        'couple_id': coupleId,
        // The Postgres hex literal, through the one function that writes bytea
        // in this app. A raw list JSON-encodes as an int array and a base64
        // string stores as its own ASCII — neither round-trips, and both have
        // shipped here before.
        'emoji_cipher': bytesToBytea(cipher),
        'emoji_nonce': bytesToBytea(nonce),
        'updated_at': at.toUtc().toIso8601String(),
      }, onConflict: 'message_id,user_id',);

  static Future<void> remove({
    required String messageId,
    required String userId,
  }) =>
      _c.from(table).delete().eq('message_id', messageId).eq('user_id', userId);

  /// One `message_reactions` row as realtime hands it over, opened.
  ///
  /// The bytea decode lives here rather than at the call site so there is one
  /// place in the app that knows how this column crosses the wire — the same
  /// reason [bytesToBytea] is the only writer.
  static Future<String?> openRow(
    Map<String, dynamic> row, {
    required String messageId,
    required String userId,
  }) async {
    Uint8List cipher;
    Uint8List nonce;
    try {
      cipher = byteaToBytes(row['emoji_cipher']);
      nonce = byteaToBytes(row['emoji_nonce']);
    } catch (e) {
      debugPrint('[reactions] row cipher unreadable: ${e.runtimeType}');
      return null;
    }
    return open(
      cipher: cipher,
      nonce: nonce,
      messageId: messageId,
      userId: userId,
    );
  }

  /// The broadcast payload, apart from the send so both halves can be tested
  /// against each other — the same split ChatBroadcastService uses, and for the
  /// same reason: this is a SECOND wire for the same content, and it has to
  /// carry ciphertext or encrypting the column would still put every reaction
  /// across Supabase Realtime in the clear.
  ///
  /// A null [sealed] IS the removal. There is no separate flag, so there is
  /// nothing that can disagree with the payload itself.
  static Map<String, dynamic> broadcastPayload({
    required String from,
    required String messageId,
    required DateTime at,
    SealedReaction? sealed,
  }) =>
      {
        'from': from,
        'messageId': messageId,
        'at': at.toUtc().toIso8601String(),
        // base64, NOT the `\x` hex the column takes — this is a JSON wire, and
        // hex would double every payload.
        if (sealed != null) 'cipher': base64Encode(sealed.cipher),
        if (sealed != null) 'nonce': base64Encode(sealed.nonce),
      };

  /// The receiving half of [broadcastPayload]. Null when the payload names no
  /// reaction, which the chat treats as nothing to apply.
  ///
  /// The returned emoji is still sealed — the caller runs it through [open],
  /// the same pass the database rows use. One decryption implementation, not
  /// two.
  static ReactionBroadcast? fromBroadcast(Map<String, dynamic> payload) {
    final from = payload['from']?.toString();
    final messageId = payload['messageId']?.toString();
    final at = DateTime.tryParse(payload['at']?.toString() ?? '');
    if (from == null || messageId == null || at == null) return null;
    return ReactionBroadcast(
      from: from,
      messageId: messageId,
      at: at.toLocal(),
      cipher: _b64(payload['cipher']),
      nonce: _b64(payload['nonce']),
    );
  }

  /// A malformed key costs the ciphertext, never the event: a removal carries
  /// none at all, and telling the two apart is the whole of the payload.
  static Uint8List? _b64(dynamic v) {
    if (v == null) return null;
    try {
      return base64Decode(v.toString());
    } catch (_) {
      return null;
    }
  }
}

/// One reaction as it came off the broadcast wire, before it is opened.
@immutable
class ReactionBroadcast {
  const ReactionBroadcast({
    required this.from,
    required this.messageId,
    required this.at,
    this.cipher,
    this.nonce,
  });

  final String from;
  final String messageId;
  final DateTime at;
  final Uint8List? cipher;
  final Uint8List? nonce;

  /// No ciphertext means the sender took their reaction back.
  bool get isRemoval => cipher == null || nonce == null;
}

/// Every reaction the open conversation is showing, and the rules for changing
/// them.
///
/// Outside the chat screen for the reason `ChatSelection` is: inside it, none
/// of this could be tested without driving the whole conversation, and a
/// version that painted nothing at all would still pass the suite. The screen
/// keeps one of these and does nothing to reactions except through it.
class ChatReactionStore {
  final ReactionsByMessage _byMessage = {};

  /// Last time a change was applied for one (message, person) — REMOVALS
  /// INCLUDED.
  ///
  /// Without it a removal takes with it the timestamp needed to reject a stale
  /// add arriving a moment later, and over two wires that do not preserve order
  /// between them that is a reaction the user took back coming back on its own.
  final Map<String, DateTime> _clock = {};

  /// A monotonic count of accepted writes, and the value it stood at when each
  /// (message, person) was last written.
  ///
  /// Not a clock — a clock cannot answer this question. [mergeFetched] has to
  /// know which entries the store learned about WHILE its own SELECT was in
  /// flight, and those arrive stamped with the partner's timeline, not with
  /// anything this device can compare against its own.
  int _writes = 0;
  final Map<String, int> _seq = {};

  /// Read before issuing a fetch; handed back to [mergeFetched].
  int get writes => _writes;

  Map<String, ChatReaction>? forMessage(String messageId) =>
      _byMessage[messageId];

  String? emojiOf(String messageId, String userId) =>
      _byMessage[messageId]?[userId]?.emoji;

  int get messagesWithReactions => _byMessage.length;

  /// What a tap on [emoji] means for [userId]: the emoji to set, or null to
  /// take it back. Tapping what you already left removes it — the toggle lives
  /// here so the bar, the chips and a test cannot disagree about it.
  String? tap(String messageId, String userId, String emoji) =>
      emojiOf(messageId, userId) == emoji ? null : emoji;

  /// The ONE writer. Answers whether anything actually changed, so a caller can
  /// skip its setState rather than repaint a conversation for an echo of what
  /// is already on screen.
  ///
  /// Last-writer-wins per person, by that person's own clock: it orders their
  /// events against themselves, which is all that is needed, and never asks the
  /// two handsets to agree about the time.
  ///
  /// A REMOVAL wins a tie and an ADD does not. The tie is reachable and it is
  /// not symmetric: a row's `updated_at` is written by the add, so a removal
  /// derived from that row carries the same instant — and the two wires can
  /// deliver them either way round, because the add's branch parks on a decrypt
  /// (and on the couple-key derive) while the removal's does not. Accepting the
  /// late add would put back a reaction its owner had already taken away.
  bool apply(String messageId, String userId, String? emoji, DateTime at) {
    final key = '$messageId|$userId';
    final last = _clock[key];
    if (last != null &&
        (emoji == null ? last.isAfter(at) : !at.isAfter(last))) {
      return false;
    }
    _clock[key] = at;
    _seq[key] = ++_writes;
    final byUser = _byMessage[messageId];
    if (emoji == null) {
      if (byUser == null) return false;
      final had = byUser.remove(userId) != null;
      if (byUser.isEmpty) _byMessage.remove(messageId);
      return had;
    }
    if (byUser?[userId]?.emoji == emoji) return false;
    (byUser ?? (_byMessage[messageId] = {}))[userId] =
        ChatReaction(emoji: emoji, at: at);
    return true;
  }

  /// One reaction off the broadcast wire, opened and applied.
  ///
  /// The echo guard is here rather than at the call site because it is part of
  /// the rule, not part of the plumbing: our own reaction is already on screen
  /// and may already have been changed again, so the copy that comes back off
  /// the wire is always the older answer.
  Future<bool> applyIncoming(
    ReactionBroadcast r, {
    required String? myUid,
  }) async {
    if (r.from == myUid) return false;
    if (r.isRemoval) return apply(r.messageId, r.from, null, r.at);
    final emoji = await ChatReactionRepository.open(
      cipher: r.cipher!,
      nonce: r.nonce!,
      messageId: r.messageId,
      userId: r.from,
    );
    if (emoji == null) return false;
    return apply(r.messageId, r.from, emoji, r.at);
  }

  /// Drop everything this store believes about one (message, person),
  /// including the ordering it believed it under.
  ///
  /// For the two cases where this device's opinion is simply void and only the
  /// server can answer: a write the server refused for good, and a DELETE off
  /// the durable wire — which under RLS is stripped to the primary key, so it
  /// carries no timestamp at all. Inventing one for either was worse than
  /// admitting there isn't one: a DELETE clocked one tick past the LATEST known
  /// write killed a re-add that had already arrived over the faster wire, and
  /// then outranked that re-add's own durable INSERT forever.
  void forget(String messageId, String userId) {
    final key = '$messageId|$userId';
    final byUser = _byMessage[messageId];
    if (byUser != null) {
      byUser.remove(userId);
      if (byUser.isEmpty) _byMessage.remove(messageId);
    }
    _clock.remove(key);
    _seq.remove(key);
    _writes++;
  }

  /// Fold a freshly fetched page in UNDER what the store already knows.
  ///
  /// [asOfWrites] is [writes] read BEFORE the SELECT was issued. The page is a
  /// snapshot of that moment and both live wires are already delivering by the
  /// time it comes back — on a cold open the decrypt inside the fetch parks for
  /// as long as the couple key takes to derive. Overwriting wholesale there
  /// erased a partner's live reaction and this device's own just-landed tap.
  ///
  /// Rows the page does NOT have are still removed — that is how a reaction
  /// taken back while the socket was down catches up — but only where nothing
  /// has touched that entry since the snapshot.
  void mergeFetched(ReactionsByMessage fetched, {required int asOfWrites}) {
    for (final messageId in _byMessage.keys.toList()) {
      final byUser = _byMessage[messageId];
      if (byUser == null) continue;
      for (final userId in byUser.keys.toList()) {
        if (fetched[messageId]?.containsKey(userId) ?? false) continue;
        final key = '$messageId|$userId';
        if ((_seq[key] ?? 0) > asOfWrites) continue;
        byUser.remove(userId);
        if (byUser.isEmpty) _byMessage.remove(messageId);
        // FORGET the clock as well. A prune is not a removal: it says the
        // server had no row at that instant, not that anyone took one back. An
        // earlier version kept the timestamp, and with an ADD required to be
        // strictly newer that made every prune permanent — the same write
        // returning on the durable wire (its updated_at IS the pruned instant),
        // the pending overlay re-applying at intent.at, and every later page
        // were all refused on the tie. A reaction still visible on the
        // partner's phone was gone from this one for the life of the screen.
        _clock.remove(key);
        _seq.remove(key);
        _writes++;
      }
    }
    for (final byMessage in fetched.entries) {
      for (final byUser in byMessage.value.entries) {
        apply(byMessage.key, byUser.key, byUser.value.emoji, byUser.value.at);
      }
    }
  }

  void clear() {
    _byMessage.clear();
    _clock.clear();
    _seq.clear();
  }
}

/// One reaction the user has committed to that has not reached the server yet.
class ReactionIntent {
  ReactionIntent({
    required this.messageId,
    required this.coupleId,
    required this.userId,
    required this.at,
    this.cipherB64,
    this.nonceB64,
    this.emoji,
  });

  factory ReactionIntent.fromJson(Map<String, dynamic> j) => ReactionIntent(
        messageId: j['m']?.toString() ?? '',
        coupleId: j['c']?.toString() ?? '',
        userId: j['u']?.toString() ?? '',
        at: DateTime.tryParse(j['t']?.toString() ?? '') ?? DateTime.now(),
        cipherB64: j['x']?.toString(),
        nonceB64: j['n']?.toString(),
      );

  final String messageId;
  final String coupleId;
  final String userId;
  final DateTime at;

  /// Base64 of the sealed emoji, or null when this intent is a REMOVAL.
  ///
  /// Base64 rather than the `\x` hex the column takes: this is a JSON wire and
  /// hex would double it. It becomes hex at the moment of the write.
  final String? cipherB64;
  final String? nonceB64;

  /// The plaintext, in memory only, so the screen can repaint a pending
  /// reaction over a page it has just fetched. Never serialized — the send
  /// queue holds the same line for message bodies.
  String? emoji;

  bool get isRemoval => cipherB64 == null;

  int attempts = 0;
  DateTime? nextAttempt;

  Map<String, dynamic> toJson() => {
        'm': messageId,
        'c': coupleId,
        'u': userId,
        't': at.toUtc().toIso8601String(),
        if (cipherB64 != null) 'x': cipherB64,
        if (nonceB64 != null) 'n': nonceB64,
      };
}

/// Reactions the user has made that the server has not accepted yet.
///
/// A singleton rather than screen state, for the reason ChatSendQueue is one:
/// the chat screen is disposed every time the user changes tab or the disguise
/// cover goes up, and a reaction made a second before that must still land. It
/// survives the process too — Android kills this app while it is backgrounded,
/// which here is the ordinary case and not a rare one.
///
/// What reaches the disk is ciphertext and two ids. The emoji itself is never
/// written down in the clear.
class ChatReactionOutbox extends ChangeNotifier {
  ChatReactionOutbox._();

  static final ChatReactionOutbox instance = ChatReactionOutbox._();

  /// One pending intent per message. A later tap on the same message replaces
  /// the earlier one rather than queueing behind it: only the last thing the
  /// user chose has ever been true, and draining a stack of superseded
  /// reactions would make the partner watch them change their mind.
  final Map<String, ReactionIntent> _pending = {};

  /// Intents the server refused for a reason retrying cannot fix. Drained by
  /// the screen, which takes back its optimistic paint and says so.
  final List<ReactionIntent> _refused = [];

  String? _uid;
  bool _flushing = false;
  Timer? _timer;

  /// Bumped by every [bindUser] and every [endSession]. A flush already inside
  /// its loop reads it after each await: clearing the pending map does not stop
  /// a loop that has already snapshotted what it is about to attempt, and those
  /// attempts would go out under the NEXT account's session.
  int _session = 0;

  /// Attempt N waits this long. Past the end of the list it stays at the last
  /// value rather than giving up — a queue that gives up has silently dropped
  /// something the user did.
  static const _backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
    Duration(seconds: 20),
    Duration(seconds: 45),
    Duration(seconds: 90),
    Duration(minutes: 3),
  ];

  Map<String, ReactionIntent> get pending => Map.unmodifiable(_pending);

  /// Bind the queue to the signed-in account, restoring what it left behind.
  ///
  /// Scoped by user id on purpose: two accounts share one handset, and a queue
  /// keyed only by device would hand the second account the first's unsent
  /// reactions — with a couple key that cannot open them and a couple_id RLS
  /// will refuse.
  Future<void> bindUser(String uid) async {
    if (_uid == uid) return;
    _session++;
    _uid = uid;
    _pending.clear();
    _refused.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key(uid)) ?? const [];
      for (final s in raw) {
        final intent =
            ReactionIntent.fromJson(jsonDecode(s) as Map<String, dynamic>);
        if (intent.messageId.isEmpty || intent.userId != uid) continue;
        _pending[intent.messageId] = intent;
      }
    } catch (e) {
      debugPrint('[reactions] outbox restore failed: ${e.runtimeType}');
    }
    // Recover the plaintext the disk copy deliberately does not hold, so a
    // restored intent can still be painted over a freshly fetched page.
    for (final intent in _pending.values) {
      final cipher = intent.cipherB64;
      if (cipher == null) continue;
      intent.emoji = await ChatReactionRepository.open(
        cipher: base64Decode(cipher),
        nonce: base64Decode(intent.nonceB64 ?? ''),
        messageId: intent.messageId,
        userId: intent.userId,
      );
    }
    if (_pending.isNotEmpty) notifyListeners();
    unawaited(flush());
  }

  /// Accept a reaction — or, with a null [sealed], its removal — and start
  /// trying to land it.
  Future<void> enqueue({
    required String coupleId,
    required String messageId,
    required String userId,
    required SealedReaction? sealed,
    required DateTime at,
  }) async {
    // Arrival order is not decision order. Sealing waits on the couple-key
    // derive, which on a cold start is a publish, a fetch and an X25519 — while
    // a REMOVAL has nothing to seal and no await at all. So the user's later
    // "take it back" can be queued, and even sent, before the earlier add
    // finishes sealing; without this the stale add overwrites it and the
    // reaction returns to both phones at the next restart.
    final queued = _pending[messageId];
    if (queued != null && queued.at.isAfter(at)) return;
    _pending[messageId] = ReactionIntent(
      messageId: messageId,
      coupleId: coupleId,
      userId: userId,
      at: at,
      cipherB64: sealed == null ? null : base64Encode(sealed.cipher),
      nonceB64: sealed == null ? null : base64Encode(sealed.nonce),
      emoji: sealed?.emoji,
    );
    await _persist();
    notifyListeners();
    await flush();
  }

  /// Intents the server refused permanently, handed over exactly once.
  List<ReactionIntent> takeRefusals() {
    if (_refused.isEmpty) return const [];
    final out = List<ReactionIntent>.from(_refused);
    _refused.clear();
    return out;
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final session = _session;
      while (session == _session) {
        final now = DateTime.now();
        final due = _pending.values
            .where((i) => i.nextAttempt == null || !i.nextAttempt!.isAfter(now))
            .toList();
        if (due.isEmpty) break;
        for (final intent in due) {
          if (session != _session) return;
          await _attempt(intent);
        }
      }
    } finally {
      _flushing = false;
    }
    _arm();
  }

  Future<void> _attempt(ReactionIntent intent) async {
    intent.attempts++;
    try {
      if (intent.isRemoval) {
        await ChatReactionRepository.remove(
          messageId: intent.messageId,
          userId: intent.userId,
        );
      } else {
        await ChatReactionRepository.put(
          coupleId: intent.coupleId,
          messageId: intent.messageId,
          userId: intent.userId,
          cipher: base64Decode(intent.cipherB64!),
          nonce: base64Decode(intent.nonceB64 ?? ''),
          at: intent.at,
        );
      }
      // Only if this is still the intent that was sent. A tap during the round
      // trip replaced it, and dropping the replacement would lose the newer
      // choice.
      if (identical(_pending[intent.messageId], intent)) {
        _pending.remove(intent.messageId);
      }
      _log(intent, ok: true, error: null);
      await _persist();
      notifyListeners();
    } catch (e) {
      _log(intent, ok: false, error: e);
      if (_permanent(e)) {
        if (identical(_pending[intent.messageId], intent)) {
          _pending.remove(intent.messageId);
        }
        _refused.add(intent);
        await _persist();
        notifyListeners();
        return;
      }
      final i = intent.attempts - 1;
      intent.nextAttempt = DateTime.now().add(
        _backoff[i < _backoff.length ? i : _backoff.length - 1],
      );
    }
  }

  /// Every attempt, win or lose, with the reason and the try count — a reaction
  /// that never lands must not be silent about how hard it tried. The message
  /// id is a correlation key; the emoji never appears.
  void _log(ReactionIntent intent, {required bool ok, required Object? error}) {
    Diag.record(DiagArea.receipt, 'reaction_write', corr: intent.messageId,
        fields: {
          'removal': intent.isRemoval,
          'attempt_n': intent.attempts,
          'ok': ok,
          'error_class': error?.runtimeType.toString(),
          'pg_code': error is PostgrestException ? error.code : null,
        },);
    if (kDebugMode) {
      debugPrint('[reactions] attempt ${intent.attempts} '
          '${intent.isRemoval ? 'remove' : 'put'} ${intent.messageId}: '
          '${ok ? 'ok' : error.runtimeType}');
    }
  }

  /// Whether retrying could ever help. Everything not named here — no network,
  /// a timeout, a 5xx — stays in the queue.
  @visibleForTesting
  static bool permanent(Object e) => _permanent(e);

  static bool _permanent(Object e) {
    if (e is! PostgrestException) return false;
    final code = e.code;
    // RLS refused it, the message is gone, or the payload will never parse.
    if (code == '42501' || code == '23503' || code == '22P02') return true;
    final status = int.tryParse(code ?? '');
    return status != null &&
        status >= 400 &&
        status < 500 &&
        status != 408 &&
        status != 429;
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    DateTime? soonest;
    for (final i in _pending.values) {
      final at = i.nextAttempt;
      if (at == null) continue;
      if (soonest == null || at.isBefore(soonest)) soonest = at;
    }
    if (soonest == null) return;
    final wait = soonest.difference(DateTime.now());
    _timer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(flush()),
    );
  }

  Future<void> _persist() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_pending.isEmpty) {
        await prefs.remove(_key(uid));
        return;
      }
      await prefs.setStringList(
        _key(uid),
        _pending.values.map((i) => jsonEncode(i.toJson())).toList(),
      );
    } catch (e) {
      debugPrint('[reactions] outbox persist failed: ${e.runtimeType}');
    }
  }

  static String _key(String uid) => 'chat_reaction_outbox_$uid';

  /// Everything that must not outlive a session.
  ///
  /// Without it the queue kept the signed-out account's `_uid` and its armed
  /// backoff timer — up to three minutes — and fired the retry under whatever
  /// session came next. RLS refuses that (`user_id = auth.uid()`), which the
  /// outbox reads as permanent and drops, so the reaction was lost for good
  /// rather than resumed at the next sign-in. The in-memory copy also holds
  /// `intent.emoji` in the clear, and that belongs to the account that just
  /// left.
  ///
  /// The DISK copy deliberately stays: it is ciphertext plus two ids under a
  /// per-user key, and [bindUser] restores and re-flushes it when that person
  /// signs back in. Nulling `_uid` is what lets it — bindUser returns early on
  /// a uid it believes is already bound.
  void endSession() {
    _session++;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _refused.clear();
    _uid = null;
    _flushing = false;
  }
}
