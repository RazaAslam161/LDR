import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/closer/closer_crypto.dart' as closer;
import 'package:miles/features/closer/memory_threads/memory_photo_repository.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';
import 'package:miles/features/closer/wish_jar/wish_jar_repository.dart';
import 'package:miles/features/gallery/gallery_repository.dart';
import 'package:miles/features/vault/vault_repository.dart';

/// What the user may tick on the export screen. One entry per independent
/// step, so one module failing names itself and the rest still run.
enum ExportModule { profile, chat, gallery, memories, wishJar, vault }

/// One thing that could not be exported: a name the OWNER may see on their own
/// screen, and the failure's class. Only the class ever leaves the device —
/// see [DataExportService._reportShortfall].
class ExportFailure {
  const ExportFailure(this.item, this.reason);
  final String item;
  final String reason;
}

/// One module's honest accounting: what landed in the folder, what did not.
class ModuleSummary {
  ModuleSummary(this.module, this.label);
  final ExportModule module;
  final String label;
  int exported = 0;
  final List<ExportFailure> failures = [];
}

/// The whole run's accounting, module by module. [cancelled] means the user
/// (or leaving the screen) stopped it — everything already written stays.
class ExportSummary {
  const ExportSummary({required this.modules, required this.cancelled});
  final List<ModuleSummary> modules;
  final bool cancelled;
  int get exported => modules.fold(0, (n, m) => n + m.exported);
  int get failed => modules.fold(0, (n, m) => n + m.failures.length);
}

/// Thrown between items when the caller has asked to stop. The item in flight
/// finishes first — a half-written video is worse than a slightly later stop.
class _ExportCancelled implements Exception {
  const _ExportCancelled();
}

/// Writes a decrypted copy of the couple's history into a folder the user
/// picked.
///
/// This exists because the app is the container for the couple's entire
/// history and E2EE makes this the ONLY place an export can ever be built:
/// the server holds ciphertext it cannot open, so "download my data" has to
/// run on the owner's device, with the owner's keys, or not at all.
///
/// Everything here is read-only against the existing repositories — the same
/// fetch, sign and decrypt paths the screens use, so the export can never show
/// more than the app can. The two deliberate exclusions are part of the
/// design, not gaps: the partner's unmatched wish-jar entries stay hidden
/// (they are hidden IN the app, by design, and an export must not be the way
/// around that), and nothing is uploaded anywhere — bytes go from the app's
/// backends straight into the user's folder.
class DataExportService {
  DataExportService._();

  /// Streamed file writes into a SAF tree — see MainActivity's 'miles/export'
  /// handler for the other half of the protocol.
  static const channel = MethodChannel('miles/export');

  /// ~512KB per hop across the channel. Downloads stream through it, so a
  /// multi-GB chat video is never whole in memory — but the two DECRYPT paths
  /// (owned vault files, memory photos) do hold the whole file for a moment:
  /// EncryptedMediaCache hands back complete plaintext, the same shape the
  /// in-app viewer already has. The chunking bounds the channel, not those.
  static const chunkBytes = 512 * 1024;

  /// Opens the system folder picker. Answers the persisted tree URI, or null
  /// when the user backed out — which is an answer, not an error.
  static Future<String?> pickFolder() =>
      channel.invokeMethod<String>('pickFolder');

  // ─── Pure helpers (unit-tested; everything below them needs a device) ────

  /// A string safe to hand SAF as one path segment. Separators, the Windows
  /// reserved set and control characters become '_' (exported folders get
  /// copied to laptops, and a name that is legal on Android and unreadable on
  /// the machine it was exported FOR is a broken export); runs of dots are
  /// collapsed so '..' can never climb; the tail survives a cap rather than
  /// the head, because the tail is where the extension lives.
  @visibleForTesting
  static String sanitizeName(String raw) {
    var out = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    out = out.replaceAll(RegExp(r'\.\.+'), '_').trim();
    while (out.startsWith('.')) {
      out = out.substring(1);
    }
    if (out.length > 120) out = out.substring(out.length - 120);
    return out.isEmpty ? '_' : out;
  }

  /// [segments] joined into the relative path the channel takes, each segment
  /// sanitized on the way through.
  @visibleForTesting
  static String relativePath(List<String> segments) =>
      segments.map(sanitizeName).join('/');

  @visibleForTesting
  static String baseName(String path) => path.split('/').last;

  /// The one folder a run writes into, directly under the picked root. Every
  /// path this service builds starts with it, so two runs can never interleave
  /// and the provider's collision suffixes stop crossing run boundaries.
  /// Deliberately no app name — the folder outlives the phone, and the
  /// launcher disguise's point is that the product's name is not written where
  /// a stranger might read it. Local time, because "the export I made this
  /// afternoon" is how the owner will look for it.
  @visibleForTesting
  static String runFolderName(DateTime at) {
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'export-${l.year}-${two(l.month)}-${two(l.day)}-'
        '${two(l.hour)}${two(l.minute)}';
  }

  /// The mime a created file is registered under. Best-effort by extension:
  /// SAF only uses it for the file's icon and for apps that filter by type,
  /// and octet-stream is always safe.
  @visibleForTesting
  static String mimeForName(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'm4a' => 'audio/mp4',
      'json' => 'application/json',
      'txt' => 'text/plain',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
  }

  /// Inverse direction, for files written from bytes whose row knows the mime.
  @visibleForTesting
  static String extForMime(String mime) => switch (mime) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'video/mp4' => 'mp4',
        'video/quicktime' => 'mov',
        'audio/mp4' => 'm4a',
        _ => 'bin',
      };

  /// The file name a message's media exports under, or null when the message
  /// carries none. `<seq>_` prefixes keep the folder in conversation order
  /// and make collisions impossible; a file message is named by what the
  /// bubble shows (its display name travels in `body`), everything else by
  /// its storage object's name.
  @visibleForTesting
  static String? chatMediaName(Message m) {
    if (m.deletedForEveryone) return null;
    final path = switch (m.kind) {
      'image' =>
        m.imagePath == null ? null : MediaUrls.toPath(chatBucket, m.imagePath!),
      'voice' =>
        m.voicePath == null ? null : MediaUrls.toPath(chatBucket, m.voicePath!),
      'video' => m.videoPath == null
          ? null
          : MediaUrls.toPath(privateBucket, m.videoPath!),
      'file' =>
        m.filePath == null ? null : MediaUrls.toPath(filesBucket, m.filePath!),
      _ => null,
    };
    if (path == null) return null;
    final shown = m.kind == 'file' ? (m.body ?? baseName(path)) : baseName(path);
    return '${m.seq}_${sanitizeName(shown)}';
  }

  /// One transcript row. Dates are ISO-8601 UTC — the export outlives the
  /// phone whose local zone stamped them. A deleted-for-everyone message
  /// exports as the same placeholder both partners already see, never its
  /// content; an undecryptable body says so instead of exporting silence,
  /// exactly as the bubble does.
  @visibleForTesting
  static Map<String, Object?> transcriptEntry(
    Message m, {
    required String? myId,
    required String myName,
    required String partnerName,
    String? mediaName,
  }) {
    final deleted = m.deletedForEveryone;
    // [mediaName] is the name the provider ACTUALLY created for this
    // message's download (collision suffixes and added extensions make it
    // differ from the predicted one). Without it — a failed download — the
    // predicted name stands, and the failure row beside it says the file is
    // not there.
    final media = deleted ? null : (mediaName ?? chatMediaName(m));
    return {
      'id': m.id,
      'at': m.createdAt.toUtc().toIso8601String(),
      'sender': m.isMine(myId) ? myName : partnerName,
      'kind': m.kind,
      if (deleted) 'deleted': true,
      if (!deleted && m.body != null) 'text': m.body,
      if (!deleted && m.bodyUndecryptable) 'undecryptable': true,
      if (media != null) 'media': 'media/$media',
      if (!deleted && m.voiceDurationMs != null)
        'voiceDurationMs': m.voiceDurationMs,
      if (!deleted && m.fileSize != null) 'fileSize': m.fileSize,
      if (m.replyToId != null) 'replyTo': m.replyToId,
    };
  }

  // ─── The run ─────────────────────────────────────────────────────────────

  /// Walks every selected module and answers what happened, module by module.
  ///
  /// [onProgress] is UI-only. [cancelled] is polled between items; the item
  /// in flight always finishes. The vault module assumes the CALLER verified
  /// the vault PIN — the screen gates the checkbox, the same way the vault
  /// gate screen gates the vault.
  ///
  /// Throws only when the run folder's README or .nomedia cannot be written:
  /// a folder that refuses a 40-line text file will refuse everything after
  /// it, and six modules of the same failure would bury the one fact that
  /// matters.
  static Future<ExportSummary> run({
    required SessionState session,
    required String treeUri,
    required Set<ExportModule> modules,
    required void Function(String module, String item) onProgress,
    required bool Function() cancelled,
  }) async {
    final out = <ModuleSummary>[];
    var stopped = false;

    void check() {
      if (cancelled()) throw const _ExportCancelled();
    }

    final root = runFolderName(DateTime.now());

    // First, unconditionally: a folder of unlabeled files a year from now is
    // exactly the kind of quiet data leak the warning screen promises not to
    // create. If this write fails, nothing else would have succeeded.
    await _writeBytes(treeUri, relativePath([root, 'README.txt']), 'text/plain',
        Uint8List.fromList(utf8.encode(_readmeText)),);

    // '.nomedia' keeps Android's media scanner out of the folder, so the
    // decrypted copies do not surface in the phone's gallery app the moment
    // the run ends. The raw path deliberately BYPASSES relativePath:
    // sanitizeName strips leading dots (its no-hidden-files rule), and a
    // 'nomedia' without its dot means nothing to the scanner. Best-effort by
    // nature — backups and copies elsewhere ignore it — but written with the
    // same fatality as the README: a folder that refuses it refuses plain
    // files, and the run is over either way.
    await _writeBytes(
        treeUri, '$root/.nomedia', 'application/octet-stream', Uint8List(0),);

    Future<void> guarded(
      ExportModule module,
      String label,
      Future<void> Function(ModuleSummary s) body,
    ) async {
      if (!modules.contains(module) || stopped) return;
      final s = ModuleSummary(module, label);
      out.add(s);
      try {
        await body(s);
      } on _ExportCancelled {
        stopped = true;
      } catch (e) {
        // The module names itself and the rest continue — one dead repository
        // must not cost the user the five that work.
        s.failures.add(ExportFailure(label, '${e.runtimeType}'));
      }
    }

    await guarded(ExportModule.profile, 'Profile',
        (s) => _runProfile(session, treeUri, root, s),);
    await guarded(ExportModule.chat, 'Chat',
        (s) => _runChat(session, treeUri, root, s, onProgress, check),);
    await guarded(ExportModule.gallery, 'Gallery',
        (s) => _runGallery(session, treeUri, root, s, onProgress, check),);
    await guarded(ExportModule.memories, 'Memories',
        (s) => _runMemories(session, treeUri, root, s, onProgress, check),);
    await guarded(ExportModule.wishJar, 'Wish Jar',
        (s) => _runWishJar(session, treeUri, root, s),);
    await guarded(ExportModule.vault, 'Private Vault',
        (s) => _runVault(treeUri, root, s, onProgress, check),);

    final summary = ExportSummary(modules: out, cancelled: stopped);
    _reportShortfall(summary);
    return summary;
  }

  /// Counts only. The failing modules' names and the first failure's class —
  /// never an item name, a path, or anything a couple wrote.
  static void _reportShortfall(ExportSummary summary) {
    if (summary.failed == 0) return;
    final failing = [
      for (final m in summary.modules)
        if (m.failures.isNotEmpty) m.module.name,
    ].join('+');
    ErrorReporter.report(
      ParseShortfall(
        'export $failing',
        parsed: summary.exported,
        of: summary.exported + summary.failed,
        first: summary.modules
            .firstWhere((m) => m.failures.isNotEmpty)
            .failures
            .first
            .reason,
      ),
      null,
      kind: 'export',
      // The cap-bypass exists for exactly this call: a run failing across
      // hundreds of items shares its broken backend with the app around it,
      // so by the time this single end-of-run row is built the five-per-
      // process cap is usually already spent on the same outage's other
      // reports — and this is the one row that carries the counts.
      force: true,
    );
  }

  // ─── Modules ─────────────────────────────────────────────────────────────

  static Future<void> _runProfile(
    SessionState session,
    String treeUri,
    String root,
    ModuleSummary s,
  ) async {
    final profile = session.profile;
    final couple = session.couple;
    await _writeBytes(treeUri, relativePath([root, 'profile.json']),
        'application/json', _jsonBytes({
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'displayName': profile?.displayName,
      'email': SupabaseService.client.auth.currentUser?.email,
      'status': profile?.statusMessage,
      'timezone': profile?.timezone,
      'joined': profile?.createdAt.toUtc().toIso8601String(),
      'partner': session.partner?.displayName,
      'coupleSince': couple?.createdAt.toUtc().toIso8601String(),
      if (couple?.anniversaryDate != null)
        'anniversary':
            couple!.anniversaryDate!.toIso8601String().split('T').first,
    }),);
    s.exported++;
  }

  static Future<void> _runChat(
    SessionState session,
    String treeUri,
    String root,
    ModuleSummary s,
    void Function(String module, String item) onProgress,
    void Function() check,
  ) async {
    final coupleId = session.couple?.id;
    if (coupleId == null) throw StateError('not linked');
    final uid = SupabaseService.currentUserId;
    if (uid == null) {
      // The same refusal _runWishJar makes. With no uid, isMine() answers
      // false for every message and the entire transcript exports attributed
      // to the partner — a wrong export, not a degraded one. A named row,
      // never a silent mis-attribution.
      s.failures.add(const ExportFailure('Chat', 'NotSignedIn'));
      return;
    }
    final myName = session.profile?.displayName ?? 'Me';
    final partnerName = session.partner?.displayName ?? 'Partner';

    // The full transcript, through the same paged fetch the catch-up path
    // uses (hydration of any ciphertext rows included — fetchSince runs it).
    // fetch() alone caps at the newest 300, which for the app's main promise
    // — "your entire history" — is not an export, it is a sample.
    final messages = <Message>[];
    var afterSeq = 0;
    while (true) {
      onProgress('Chat', 'reading messages (${messages.length})');
      final page = await ChatRepository.fetchSince(coupleId, afterSeq);
      if (page.isEmpty) break;
      messages.addAll(page);
      afterSeq = page.last.seq;
      check();
    }

    // "Delete for me" stays deleted for me: the transcript this person's own
    // screen shows is the transcript their export holds.
    final visible = [
      for (final m in messages)
        if (!m.isHiddenFor(uid)) m,
    ];

    // Media BEFORE the transcript: the provider owns each file's final name
    // (collision suffixes, extensions added for the mime), so the transcript
    // can only point at files that exist once they exist. A cancel mid-media
    // still writes the transcript below — the words are the export's core,
    // and a stop that kept the files but lost the manifest would be the
    // wrong half to lose.
    final mediaNames = <String, String>{};
    var stoppedEarly = false;
    try {
      for (final m in visible) {
        final name = chatMediaName(m);
        if (name == null) continue;
        check();
        onProgress('Chat', name);
        try {
          final url = await _chatMediaUrl(m);
          if (url == null) throw const MediaTransient();
          mediaNames[m.id] = await _downloadTo(
            treeUri: treeUri,
            relativePath: relativePath([root, 'chat', 'media', name]),
            mime: mimeForName(name),
            url: url,
          );
          s.exported++;
        } catch (e) {
          s.failures.add(ExportFailure(name, '${e.runtimeType}'));
        }
      }
    } on _ExportCancelled {
      stoppedEarly = true;
    }

    await _writeBytes(
      treeUri,
      relativePath([root, 'chat', 'transcript.json']),
      'application/json',
      _jsonBytes([
        for (final m in visible)
          transcriptEntry(m,
              myId: uid,
              myName: myName,
              partnerName: partnerName,
              mediaName: mediaNames[m.id],),
      ]),
    );
    // MESSAGES, not files written: transcript.json counted as "1" made an
    // empty transcript on a linked couple read as one thing successfully
    // exported, when the honest summary is zero messages.
    s.exported += visible.length;
    if (stoppedEarly) throw const _ExportCancelled();
  }

  /// The same signing helpers the chat screen renders from: couple_media
  /// through MediaUrls, the private and file buckets through the repository's
  /// own signed-URL helpers.
  static Future<String?> _chatMediaUrl(Message m) => switch (m.kind) {
        'image' => MediaUrls.sign(
            chatBucket, MediaUrls.toPath(chatBucket, m.imagePath!),),
        'voice' => MediaUrls.sign(
            chatBucket, MediaUrls.toPath(chatBucket, m.voicePath!),),
        'video' => ChatRepository.signedVideoUrl(m.videoPath),
        'file' => ChatRepository.signedFileUrl(m.filePath),
        _ => Future.value(),
      };

  static Future<void> _runGallery(
    SessionState session,
    String treeUri,
    String root,
    ModuleSummary s,
    void Function(String module, String item) onProgress,
    void Function() check,
  ) async {
    final coupleId = session.couple?.id;
    if (coupleId == null) throw StateError('not linked');
    // Paged until exhausted: GalleryRepository.fetch stops at the grid's 500,
    // and an export that stopped there too would be a truncation wearing a
    // clean summary. Newest-first from the repository; numbered so the folder
    // sorts the way the grid reads; one page in memory at a time.
    var i = 0;
    DateTime? cursor;
    while (true) {
      onProgress('Gallery', 'reading gallery ($i)');
      final page = await GalleryRepository.fetchPage(coupleId, before: cursor);
      if (page.isEmpty) break;
      for (final item in page) {
        check();
        i++;
        final name = '${i.toString().padLeft(4, '0')}_'
            '${sanitizeName(baseName(item.storagePath))}';
        onProgress('Gallery', name);
        try {
          // The ORIGINAL, not the thumbnail the grid warms.
          final url = await MediaUrls.sign(privateBucket, item.storagePath);
          if (url == null) throw const MediaTransient();
          await _downloadTo(
            treeUri: treeUri,
            relativePath: relativePath([root, 'gallery', name]),
            mime: item.mimeType,
            url: url,
          );
          s.exported++;
        } catch (e) {
          s.failures.add(ExportFailure(name, '${e.runtimeType}'));
        }
      }
      if (page.length < GalleryRepository.pageSize) break;
      cursor = page.last.createdAt;
      check();
    }
  }

  static Future<void> _runMemories(
    SessionState session,
    String treeUri,
    String root,
    ModuleSummary s,
    void Function(String module, String item) onProgress,
    void Function() check,
  ) async {
    final coupleId = session.couple?.id;
    if (coupleId == null) throw StateError('not linked');
    // The same derive + safety-pin gate the memory screen runs on entry. If
    // this throws there is no key to decrypt with and the whole module fails
    // with that one named reason, which is the truth.
    await closer.ensureSharedKey(session);

    // Page exactly as streamThreads does: inclusive cursor on happened_on,
    // keyed by id so the boundary overlap costs one repeat and loses none.
    final threads = <MemoryThread>[];
    final seen = <String>{};
    var unreadable = 0;
    DateTime? cursor;
    while (true) {
      onProgress('Memories', 'reading memories (${threads.length})');
      final seed =
          await MemoryThreadRepository.fetchThreads(coupleId, before: cursor);
      var added = 0;
      for (final t in seed.items) {
        if (seen.add(t.id)) {
          threads.add(t);
          added++;
        }
      }
      // Counted only on pages that brought something new: the inclusive
      // cursor makes the terminal page pure overlap, and its unreadable rows
      // were already counted when they were first fetched. Not exact — a
      // page mixing one boundary repeat with new rows can still recount an
      // unreadable row once — but that overstates, never understates, and an
      // exact count would need ids for rows that failed to parse, which is
      // what unreadable means.
      if (added > 0 || cursor == null) unreadable += seed.unreadable;
      if (added == 0 || seed.items.isEmpty) break;
      cursor = seed.items.last.happenedOn;
      check();
    }
    if (unreadable > 0) {
      s.failures.add(ExportFailure('$unreadable memories', 'Undecryptable'));
    }

    final entries = <Map<String, Object?>>[];
    for (final t in threads) {
      check();
      final photoNames = <String>[];

      // The row's fields, through the repository's own decrypt helpers and
      // — for the two fields without one — the exact associated-data strings
      // the repository sealed with (memory_thread_repository.dart: accept()
      // uses '<id>_pnote', propose() uses '<id>_place'). One failure marks
      // the whole entry rather than three counts for one bad row.
      String? title;
      String? note;
      String? partnerNote;
      String? place;
      var opened = false;
      try {
        title = await decryptTitle(t);
        note = await decryptNote(t);
        final pn = t.partnerNotePayload();
        if (pn != null) {
          partnerNote =
              await CryptoCore.decryptString(pn, associatedData: '${t.id}_pnote');
        }
        final pl = t.placePayload();
        if (pl != null) {
          place =
              await CryptoCore.decryptString(pl, associatedData: '${t.id}_place');
        }
        opened = true;
      } catch (e) {
        s.failures.add(ExportFailure('memory ${t.id}', '${e.runtimeType}'));
      }

      var photos = const <MemoryPhoto>[];
      try {
        photos = await MemoryPhotoRepository.listFor(t.id);
      } catch (e) {
        s.failures.add(ExportFailure('memory ${t.id} photos', '${e.runtimeType}'));
      }
      for (final p in photos) {
        check();
        final name = '${t.id}_${p.position}.${extForMime(p.mimeType)}';
        onProgress('Memories', name);
        try {
          // The screen's own path: ciphertext object → decrypt under the
          // couple key, bound by the frozen memory+photo associated data.
          final bytes = await EncryptedMediaCache.bytes(
            bucket: privateBucket,
            path: p.fullPath,
            associatedData: MemoryPhotoRepository.fullAdFor(p.memoryId, p.id),
          );
          final actual = await _writeBytes(treeUri,
              relativePath([root, 'memories', 'photos', name]),
              p.mimeType, bytes,);
          photoNames.add('photos/$actual');
          s.exported++;
        } catch (e) {
          s.failures.add(ExportFailure(name, '${e.runtimeType}'));
        }
      }

      // The pre-007000 inline photo, still real on the read path. photo_nonce
      // is the repository's own nearly-free predicate for "this row still has
      // one" — decryptPhoto re-reads the heavy cipher column only then.
      if (t.photoNonce != null) {
        final name = '${t.id}_inline.jpg';
        onProgress('Memories', name);
        try {
          final bytes = await decryptPhoto(t);
          if (bytes != null) {
            final actual = await _writeBytes(treeUri,
                relativePath([root, 'memories', 'photos', name]),
                'image/jpeg', bytes,);
            photoNames.add('photos/$actual');
            s.exported++;
          }
        } catch (e) {
          s.failures.add(ExportFailure(name, '${e.runtimeType}'));
        }
      }

      entries.add({
        'id': t.id,
        // toLocal() first, exactly as the memory card renders it
        // (memory_threads_screen.dart): happened_on is the DATE the user
        // picked, stored as a bare 'yyyy-MM-dd' that parses to local
        // midnight and is held as UTC — east of UTC, formatting the UTC
        // value prints the previous day.
        'happenedOn': t.happenedOn.toLocal().toIso8601String().split('T').first,
        'state': t.state.name,
        'createdAt': t.createdAt.toUtc().toIso8601String(),
        if (title != null) 'title': title,
        if (note != null) 'note': note,
        if (partnerNote != null) 'partnerNote': partnerNote,
        if (place != null) 'place': place,
        if (!opened) 'undecryptable': true,
        if (photoNames.isNotEmpty) 'photos': photoNames,
      });
    }

    await _writeBytes(
        treeUri, relativePath([root, 'memories', 'memories.json']),
        'application/json', _jsonBytes(entries),);
    s.exported++;
  }

  static Future<void> _runWishJar(
    SessionState session,
    String treeUri,
    String root,
    ModuleSummary s,
  ) async {
    final coupleId = session.couple?.id;
    final uid = SupabaseService.currentUserId;
    if (coupleId == null || uid == null) throw StateError('not linked');
    await WishJarRepository.ensureSharedKey(session);
    // OWN entries only, and that is a rule of the feature, not of the export:
    // the partner's unmatched entries are hidden in the app by design, and
    // an export that surfaced them would be a way around the jar's whole
    // promise. fetchMyEntries is the only fetch this module may ever call.
    final res =
        await WishJarRepository.fetchMyEntries(coupleId: coupleId, myId: uid);
    await _writeBytes(treeUri, relativePath([root, 'wish_jar.json']),
        'application/json', _jsonBytes([
      for (final e in res.items)
        {
          'text': e.text,
          'tags': [for (final t in e.tags) wishTagLabel(t)],
          'createdAt': e.createdAt.toUtc().toIso8601String(),
        },
    ]),);
    s.exported++;
    if (res.unreadable > 0) {
      s.failures.add(ExportFailure('${res.unreadable} entries', 'Undecryptable'));
    }
  }

  /// Only reached once the screen has verified the vault PIN — the same gate
  /// the vault itself stands behind.
  static Future<void> _runVault(
    String treeUri,
    String root,
    ModuleSummary s,
    void Function(String module, String item) onProgress,
    void Function() check,
  ) async {
    final items = await VaultRepository.items();
    // The vault's OWN key, exactly as the viewer decrypts — never the couple
    // key, which cannot open a vault blob and whose use here would be a bug.
    final vaultKey = await CryptoCore.exportVaultKeyBytes();
    final index = <Map<String, Object?>>[];

    for (final item in items) {
      check();
      final savedAt = item.createdAt.toUtc().toIso8601String();
      if (item.isNote) {
        // A note's content lands in notes.json, so it counts as exported —
        // a vault of thirty notes summarised as "1 exported" reads as loss.
        index.add({'type': 'note', 'text': item.content, 'savedAt': savedAt});
        s.exported++;
        continue;
      }
      if (item.isOwned) {
        final mime = item.mimeType ?? 'application/octet-stream';
        final name = '${item.id}.${extForMime(mime)}';
        onProgress('Private Vault', item.mediaUrl ?? name);
        try {
          final bytes = await EncryptedMediaCache.bytes(
            bucket: VaultRepository.bucket,
            path: item.storagePath!,
            associatedData: VaultRepository.fullAdFor(item.id),
            keyOverride: vaultKey,
          );
          final actual = await _writeBytes(treeUri,
              relativePath([root, 'vault', 'files', name]), mime, bytes,);
          index.add({
            'type': item.type,
            'label': item.mediaUrl,
            'file': 'files/$actual',
            'savedAt': savedAt,
          });
          s.exported++;
        } catch (e) {
          s.failures
              .add(ExportFailure(item.mediaUrl ?? name, '${e.runtimeType}'));
        }
        continue;
      }
      final legacy = item.legacyIntimatePath;
      if (legacy != null) {
        // A legacy row still points at real bytes in the couple's bucket —
        // re-signed on demand, the same way the vault viewer opens it.
        final name = '${item.id}_${sanitizeName(baseName(legacy))}';
        onProgress('Private Vault', item.mediaUrl ?? name);
        try {
          final url = await ChatRepository.signedVideoUrl(legacy);
          if (url == null) throw const MediaTransient();
          final actual = await _downloadTo(
            treeUri: treeUri,
            relativePath: relativePath([root, 'vault', 'files', name]),
            mime: mimeForName(name),
            url: url,
          );
          index.add({
            'type': item.type,
            'label': item.mediaUrl,
            'file': 'files/$actual',
            'savedAt': savedAt,
          });
          s.exported++;
        } catch (e) {
          s.failures
              .add(ExportFailure(item.mediaUrl ?? name, '${e.runtimeType}'));
        }
        continue;
      }
      // A bookmark row holding a signed URL that expired within a day of
      // being written. There are no bytes left to fetch, and pretending
      // otherwise is what the summary exists to not do.
      s.failures
          .add(ExportFailure(item.mediaUrl ?? 'saved item', 'ExpiredLink'));
    }

    await _writeBytes(
        treeUri, relativePath([root, 'vault', 'notes.json']),
        'application/json', _jsonBytes(index),);
    s.exported++;
  }

  // ─── Channel plumbing ────────────────────────────────────────────────────

  /// Answers the handle AND the display name the provider actually created.
  /// The two can differ from what was asked for — a taken name gains a
  /// " (1)" suffix, a mime can gain its extension — and every manifest
  /// pointer must name the file that EXISTS, not the one Dart requested.
  static Future<({int id, String name})> _createFile(
    String treeUri,
    String relativePath,
    String mime,
  ) async {
    final res = await channel.invokeMethod<Map<dynamic, dynamic>>('createFile', {
      'treeUri': treeUri,
      'relativePath': relativePath,
      'mime': mime,
    });
    final id = res?['id'] as int?;
    final name = res?['name'] as String?;
    if (id == null || name == null) {
      throw StateError('createFile answered no handle');
    }
    return (id: id, name: name);
  }

  static Future<void> _writeChunk(int id, Uint8List bytes) =>
      channel.invokeMethod<void>('writeChunk', {'id': id, 'bytes': bytes});

  static Future<void> _closeFile(int id) =>
      channel.invokeMethod<void>('closeFile', {'id': id});

  /// In-memory bytes (JSON, decrypted photos and vault files — whole in
  /// memory by then, see [chunkBytes]) out to the folder, chunked across the
  /// channel. Answers the file name the provider actually created.
  static Future<String> _writeBytes(
    String treeUri,
    String relativePath,
    String mime,
    Uint8List bytes,
  ) async {
    final file = await _createFile(treeUri, relativePath, mime);
    try {
      var at = 0;
      while (at < bytes.length) {
        final end = min(at + chunkBytes, bytes.length);
        await _writeChunk(file.id, Uint8List.sublistView(bytes, at, end));
        at = end;
      }
    } finally {
      // Closed even when a chunk failed: an abandoned handle would hold the
      // stream open for the rest of the process. The partial file stays in
      // the folder and its row in the summary says so.
      await _closeFile(file.id);
    }
    return file.name;
  }

  /// A signed URL streamed straight into the folder. The response is consumed
  /// chunkwise and re-buffered to [chunkBytes], so THIS path — chat media,
  /// gallery originals, legacy vault rows — never holds more than one chunk;
  /// it is the path a multi-GB chat video takes. The decrypt paths do not
  /// come through here (see [chunkBytes]). Answers the file name the
  /// provider actually created.
  static Future<String> _downloadTo({
    required String treeUri,
    required String relativePath,
    required String mime,
    required String url,
  }) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) {
        throw http.ClientException('download answered HTTP ${res.statusCode}');
      }
      final file = await _createFile(treeUri, relativePath, mime);
      try {
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in res.stream) {
          buffer.add(chunk);
          if (buffer.length >= chunkBytes) {
            await _writeChunk(file.id, buffer.takeBytes());
          }
        }
        if (buffer.isNotEmpty) {
          await _writeChunk(file.id, buffer.takeBytes());
        }
      } finally {
        await _closeFile(file.id);
      }
      return file.name;
    } finally {
      client.close();
    }
  }

  static Uint8List _jsonBytes(Object value) => Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(value)),);

  /// Deliberately does not name the app: an export folder outlives the phone
  /// it was written on, and the launcher disguise's whole point is that the
  /// product's name is not written where a stranger might read it.
  static const _readmeText = '''
About this folder

Everything here is an UNENCRYPTED copy of what was selected for export.
Anyone who can read this folder can read all of it. The app's own copies
stay encrypted on the phone and the server; deleting this folder deletes
only the copy.

Layout:
  README.txt             - this file
  .nomedia               - asks this phone's photo apps not to index the
                           folder; backups and copies made elsewhere carry
                           no such request
  profile.json           - your profile and when the two of you linked
  chat/transcript.json   - the conversation, oldest first
  chat/media/            - photos, voice notes, videos and files from chat
  gallery/               - the shared gallery's original files
  memories/memories.json - your memory threads
  memories/photos/       - their photographs, decrypted
  wish_jar.json          - your own wish jar entries (only your own)
  vault/notes.json       - your private vault's notes and file index
  vault/files/           - your private vault's files, decrypted

Each run writes its own dated folder. A re-run creates a new one beside
this one and never touches these files.
''';
}
