import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/data_export_service.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The export's pure parts, plus the wiring a unit test cannot execute.
///
/// Two kinds of test here, and the split is stated so nobody mistakes one for
/// the other:
///
///  - BEHAVIORAL: transcript shaping, SAF name sanitisation and summary
///    arithmetic are pure functions and are exercised for real.
///  - SOURCE SCAN: the MethodChannel and every repository need a device and a
///    backend, so the service's structure — which channel, which fetches,
///    which key, what reaches ErrorReporter — is pinned by reading the source,
///    the same idiom shared_media_test.dart uses against its migration.
void main() {
  Message msg({
    int seq = 1,
    String kind = 'text',
    String? body,
    String? imagePath,
    String? voicePath,
    String? videoPath,
    String? filePath,
    String senderId = 'me',
    bool deletedForEveryone = false,
    bool bodyUndecryptable = false,
    int? voiceDurationMs,
    String? replyToId,
  }) =>
      Message(
        id: 'm$seq',
        senderId: senderId,
        createdAt: DateTime(2026, 8, 1, 12, 30),
        seq: seq,
        kind: kind,
        body: body,
        imagePath: imagePath,
        voicePath: voicePath,
        videoPath: videoPath,
        filePath: filePath,
        deletedForEveryone: deletedForEveryone,
        bodyUndecryptable: bodyUndecryptable,
        voiceDurationMs: voiceDurationMs,
        replyToId: replyToId,
      );

  group('SAF names (behavioral)', () {
    test('separators, the reserved set and control chars become _', () {
      expect(DataExportService.sanitizeName(r'a/b\c'), 'a_b_c');
      expect(DataExportService.sanitizeName('a:b*c?d"e<f>g|h'),
          'a_b_c_d_e_f_g_h',);
      expect(DataExportService.sanitizeName('a\x00b\x1fc'), 'a_b_c');
    });

    test('dot runs can never climb out of the tree', () {
      // '..' as a segment is the classic escape; anything containing a run of
      // dots is collapsed rather than trusted.
      expect(DataExportService.sanitizeName('..'), '_');
      expect(DataExportService.sanitizeName('x..y'), 'x_y');
      expect(DataExportService.sanitizeName('...'), '_');
      expect(DataExportService.sanitizeName('..secret'), '_secret');
    });

    test('no hidden files, no empty names', () {
      expect(DataExportService.sanitizeName('.nomedia'), 'nomedia');
      expect(DataExportService.sanitizeName(''), '_');
      expect(DataExportService.sanitizeName('   '), '_');
    });

    test('a cap keeps the tail, where the extension lives', () {
      final long = '${'a' * 200}.jpg';
      final out = DataExportService.sanitizeName(long);
      expect(out.length, 120);
      expect(out, endsWith('.jpg'));
    });

    test('relativePath sanitises every segment it joins', () {
      expect(
        DataExportService.relativePath(['chat', 'media', 'a:b.jpg']),
        'chat/media/a_b.jpg',
      );
    });

    test('a run gets one dated container folder, no app name', () {
      // Everything a run writes lives under this one folder, so two runs
      // never interleave and the provider's collision suffixes stop crossing
      // run boundaries. The name survives relativePath unchanged.
      final name = DataExportService.runFolderName(DateTime(2026, 8, 18, 9, 5));
      expect(name, 'export-2026-08-18-0905');
      expect(DataExportService.sanitizeName(name), name);
    });

    test('unknown extensions fall back to octet-stream', () {
      expect(DataExportService.mimeForName('x.jpg'), 'image/jpeg');
      expect(DataExportService.mimeForName('x.weird'),
          'application/octet-stream',);
      expect(DataExportService.mimeForName('noext'),
          'application/octet-stream',);
      expect(DataExportService.extForMime('video/mp4'), 'mp4');
      expect(DataExportService.extForMime('application/x-thing'), 'bin');
    });
  });

  group('chat media names (behavioral)', () {
    test('seq prefix plus the storage object name', () {
      expect(
        DataExportService.chatMediaName(
            msg(seq: 42, kind: 'image', imagePath: 'cid/img_1.jpg'),),
        '42_img_1.jpg',
      );
    });

    test('a legacy public URL is reduced to its path first', () {
      // Rows written before couple_media went private hold the full URL;
      // MediaUrls.toPath is the read path everywhere else, so it is here too.
      expect(
        DataExportService.chatMediaName(msg(
          seq: 7,
          kind: 'image',
          imagePath: 'https://x.supabase.co/storage/v1/object/public/'
              'couple_media/cid/img_2.jpg',
        ),),
        '7_img_2.jpg',
      );
    });

    test('a file is named what the bubble shows, sanitised', () {
      expect(
        DataExportService.chatMediaName(msg(
          seq: 9,
          kind: 'file',
          filePath: 'cid/file_abc.pdf',
          body: 'Tax: 2026?.pdf',
        ),),
        '9_Tax_ 2026_.pdf',
      );
    });

    test('text and deleted messages export no media', () {
      expect(DataExportService.chatMediaName(msg(body: 'hi')), isNull);
      expect(
        DataExportService.chatMediaName(msg(
            kind: 'image', imagePath: 'cid/a.jpg', deletedForEveryone: true,),),
        isNull,
      );
    });
  });

  group('transcript shaping (behavioral)', () {
    Map<String, Object?> entry(Message m) => DataExportService.transcriptEntry(
          m,
          myId: 'me',
          myName: 'Raza',
          partnerName: 'Her',
        );

    test('senders resolve to display names, dates to ISO-8601 UTC', () {
      final m = msg(body: 'hello');
      final e = entry(m);
      expect(e['sender'], 'Raza');
      expect(entry(msg(senderId: 'them', body: 'hi'))['sender'], 'Her');
      expect(e['at'], m.createdAt.toUtc().toIso8601String());
      expect(e['at']! as String, endsWith('Z'));
      expect(e['text'], 'hello');
      expect(e['kind'], 'text');
    });

    test('deleted-for-everyone exports the placeholder, never the content',
        () {
      final e = entry(msg(
          kind: 'image',
          body: 'should not appear',
          imagePath: 'cid/a.jpg',
          deletedForEveryone: true,),);
      expect(e['deleted'], true);
      expect(e.containsKey('text'), isFalse);
      expect(e.containsKey('media'), isFalse);
    });

    test('an unopenable body says so instead of exporting silence', () {
      final e = entry(msg(bodyUndecryptable: true));
      expect(e['undecryptable'], true);
      expect(e.containsKey('text'), isFalse);
    });

    test('media entries point at the file the module writes', () {
      final e = entry(msg(seq: 5, kind: 'voice',
          voicePath: 'cid/voice_1.m4a', voiceDurationMs: 3200,),);
      expect(e['media'], 'media/5_voice_1.m4a');
      expect(e['voiceDurationMs'], 3200);
    });

    test("the provider's actual file name wins over the predicted one", () {
      // A collision suffix or an added extension means the created file is
      // not named what Dart asked; the pointer must follow the provider.
      final e = DataExportService.transcriptEntry(
        msg(seq: 5, kind: 'voice', voicePath: 'cid/voice_1.m4a'),
        myId: 'me',
        myName: 'Raza',
        partnerName: 'Her',
        mediaName: '5_voice_1 (1).m4a',
      );
      expect(e['media'], 'media/5_voice_1 (1).m4a');
    });

    test('replies keep their thread', () {
      expect(entry(msg(body: 'yes', replyToId: 'm1'))['replyTo'], 'm1');
    });
  });

  group('summary arithmetic (behavioral)', () {
    test('totals are the sum of the modules, failures included', () {
      final chat = ModuleSummary(ExportModule.chat, 'Chat')..exported = 10;
      chat.failures.add(const ExportFailure('a.jpg', 'MediaTransient'));
      chat.failures.add(const ExportFailure('b.mp4', 'ClientException'));
      final vault = ModuleSummary(ExportModule.vault, 'Private Vault')
        ..exported = 3;
      final s =
          ExportSummary(modules: [chat, vault], cancelled: false);
      expect(s.exported, 13);
      expect(s.failed, 2);
    });

    test('an empty run is zero everywhere, not a crash', () {
      const s = ExportSummary(modules: [], cancelled: true);
      expect(s.exported, 0);
      expect(s.failed, 0);
      expect(s.cancelled, isTrue);
    });
  });

  group('wiring (source scan — channel and repositories cannot run here)', () {
    // Normalised so a checkout with CRLF endings scans identically.
    String read(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');
    final service = read('lib/core/services/data_export_service.dart');
    final screen = read('lib/features/settings/export_screen.dart');
    final router = read('lib/core/app/router.dart');
    final settings = read('lib/features/settings/settings_screen.dart');
    final activity =
        read('android/app/src/main/kotlin/com/miles/miles/MainActivity.kt');

    test('both sides speak the same channel', () {
      expect(service, contains("MethodChannel('miles/export')"));
      expect(activity, contains('"miles/export"'));
    });

    test('every method Dart invokes exists on the Kotlin side', () {
      // [^(]* rather than [^>]*: the payload type is a nested generic
      // (Map<dynamic, dynamic>, for strict_raw_type) and the old class
      // stopped at its first '>'.
      final invoked = RegExp(r"invokeMethod<[^(]*>\(\s*'(\w+)'")
          .allMatches(service)
          .map((m) => m[1]!)
          .toSet();
      expect(invoked,
          containsAll(['pickFolder', 'createFile', 'writeChunk', 'closeFile']),);
      for (final name in invoked) {
        expect(activity, contains('"$name" ->'),
            reason: 'Dart invokes $name and MainActivity has no case for it',);
      }
    });

    test('the folder grant persists and comes from the tree picker', () {
      expect(activity, contains('ACTION_OPEN_DOCUMENT_TREE'));
      expect(activity, contains('takePersistableUriPermission'));
    });

    test('the wish jar exports OWN entries only', () {
      // The partner's unmatched entries are hidden by design; the export must
      // not be the way around that. fetchMyEntries is the only fetch the
      // module may call, and the partner-side fetch must never appear.
      expect(service, contains('fetchMyEntries'));
      expect(service, isNot(contains('fetchPartnerTagHashes')));
    });

    test('vault media decrypts under the vault key, not the couple key', () {
      expect(service, contains('exportVaultKeyBytes'));
      expect(service, contains('keyOverride: vaultKey'));
    });

    test('failures reach ErrorReporter as counts, under the export kind', () {
      // ParseShortfall carries numbers and a class name and nothing else —
      // the one reportable shape that cannot leak a couple's content. force
      // because a failing run has usually burnt the per-run cap on the same
      // outage before its own summary row is built.
      expect(service, contains('ParseShortfall'));
      expect(service, contains("kind: 'export'"));
      expect(service, contains('force: true'));
    });

    test('the chat summary counts messages, not the transcript file', () {
      // "1 exported" for transcript.json made an empty transcript on a
      // linked couple read as success; zero messages must surface as zero.
      expect(service, contains('s.exported += visible.length'));
      // And with no uid the whole transcript would mis-attribute — a named
      // failure row, never a silent wrong export.
      expect(service, contains("ExportFailure('Chat', 'NotSignedIn')"));
    });

    test('the gallery pages to exhaustion instead of stopping at the grid cap',
        () {
      expect(service, contains('GalleryRepository.fetchPage'));
      expect(service, isNot(contains('GalleryRepository.fetch(')));
    });

    test('.nomedia is written raw, dodging the no-hidden-files rule', () {
      // sanitizeName strips leading dots, and a 'nomedia' without its dot
      // means nothing to the media scanner — the bypass is the feature.
      expect(service, contains(r"'$root/.nomedia'"));
    });

    test('the screen is routed and reachable from Settings', () {
      expect(router, contains("path: '/app/settings/export'"));
      expect(settings, contains("context.push('/app/settings/export')"));
    });

    test('the screen gates: app lock before the pick, PIN before the vault',
        () {
      expect(screen, contains('AppLock.authenticate'));
      expect(screen, contains('VaultRepository.verifyPin'));
      // Toggling the vault module on runs the PIN sheet first.
      expect(screen, contains('_verifyVaultPin'));
    });

    test('leaving the screen cancels the run', () {
      // v1 is foreground-only; dispose() must request the stop the service
      // polls for, or a popped screen keeps writing decrypted files.
      expect(screen, contains('_cancelRequested = true;\n    super.dispose'));
      expect(service, contains('cancelled()'));
    });
  });
}
