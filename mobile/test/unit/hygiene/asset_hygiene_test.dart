import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Assets, held to the same standard as code: nothing ships unreferenced,
/// nothing is referenced that does not ship, and every directory has a size
/// ceiling that is a TEST, not a wish in a doc. (The culture predates this
/// file — an orphaned Lottie was hunted down by hand once; now the suite
/// does the hunting.)
void main() {
  final assetFiles = <String>[];
  for (final dir in const [
    'assets/emoji',
    'assets/sound',
    'assets/fonts',
    'assets/art',
    'assets/scene',
    'assets/presence',
    'assets/opening',
    'assets/unlink_films',
  ]) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      assetFiles.add(f.path.replaceAll(r'\', '/'));
    }
  }

  final libSource = StringBuffer();
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (f.path.endsWith('.dart')) libSource.write(f.readAsStringSync());
  }
  final lib = libSource.toString();
  final pubspec = File('pubspec.yaml').readAsStringSync();

  test('every shipped asset is referenced from lib/ (or is a license)', () {
    final orphans = <String>[];
    for (final path in assetFiles) {
      final name = path.split('/').last;
      final stem = name.split('.').first;
      // Fonts are consumed via pubspec's fonts: section; the OFL texts via
      // LicenseRegistry loads that name them explicitly.
      //
      // The quoted-stem escape hatch is SCOPED TO EMOJI deliberately. It
      // exists for one dynamic path (mood.dart builds
      // 'assets/emoji/\$key.json' from mood keys that appear as string
      // literals). Unscoped it is a hole: any asset whose stem happens to be
      // an ordinary word elsewhere in the codebase passes with no call site
      // at all — and assets/art was not even being scanned, so jar.webp
      // shipped unreferenced through both gaps at once.
      final ok = pubspec.contains(path) ||
          lib.contains(path) ||
          lib.contains(name) ||
          (path.startsWith('assets/emoji/') && lib.contains("'$stem'")) ||
          path.startsWith('assets/fonts/');
      if (!ok) orphans.add(path);
    }
    expect(orphans, isEmpty,
        reason: 'shipped but referenced by nothing — delete or wire: '
            '$orphans');
  });

  test('every asset path lib/ names actually exists', () {
    final named = RegExp(r"'(assets/[a-z0-9_/]+\.[a-z0-9]+)'")
        .allMatches(lib)
        .map((m) => m.group(1)!)
        .toSet();
    final missing = named
        .where((p) => !p.contains(r'$'))
        .where((p) => !File(p).existsSync())
        .toList();
    expect(missing, isEmpty,
        reason: 'lib/ names assets that do not ship — a runtime throw on the '
            'screen that loads them: $missing');
  });

  test('size ceilings hold', () {
    int dirSize(String dir) {
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      return d
          .listSync(recursive: true)
          .whereType<File>()
          .fold(0, (a, f) => a + f.lengthSync());
    }

    // A budget in a test is a budget; a budget in a doc is a wish.
    expect(dirSize('assets/sound'), lessThanOrEqualTo(1536 * 1024),
        reason: 'assets/sound over its 1.5MB ceiling');
    expect(dirSize('assets/fonts'), lessThanOrEqualTo(600 * 1024),
        reason: 'assets/fonts over its 600KB ceiling');
    expect(dirSize('assets/scene'), lessThanOrEqualTo(600 * 1024),
        reason: 'assets/scene over its 600KB ceiling');
    // Two busts, ~54KB. The ceiling is deliberately close to the contents:
    // this directory exists so a badge on twenty screens decodes ONE small
    // face, and the day it grows a cast is the day that stops being true.
    expect(dirSize('assets/presence'), lessThanOrEqualTo(150 * 1024),
        reason: 'assets/presence over its 150KB ceiling');
    // The Opening: one 14s H.264 film, 406x720 portrait, no audio track (the score
    // plays through MilesSound so mute and the sound-kill still govern it). 1.93MB
    // today. The ceiling leaves room for a re-master but not for a second film.
    expect(dirSize('assets/opening'), lessThanOrEqualTo(3 * 1024 * 1024),
        reason: 'assets/opening over its 3MB ceiling');
    // Eight owner-generated films + four held stages, 5.4MB at intake. The
    // ceiling leaves room for a retake, not for a second feature's worth.
    expect(dirSize('assets/unlink_films'), lessThanOrEqualTo(6 * 1024 * 1024),
        reason: 'assets/unlink_films over its 6MB ceiling');
    expect(
        dirSize('assets/emoji') +
            dirSize('assets/sound') +
            dirSize('assets/fonts') +
            dirSize('assets/art') +
            dirSize('assets/scene') +
            dirSize('assets/presence') +
            dirSize('assets/opening') +
            dirSize('assets/unlink_films') +
            dirSize('assets/motion'),
        // RAISED 6MB -> 8MB on 2026-08-31 (the Opening film) and 8MB -> 12MB on
        // 2026-09-01 (the doorstep's eight films), both the OWNER's explicit
        // decisions, recorded here because this number is the only thing that
        // actually enforces them. Standing at ~9.9MB after the films — a
        // deliberate raise with real headroom, not a number moved to go green.
        lessThanOrEqualTo(12 * 1024 * 1024),
        reason: 'assets/ total over its 12MB ceiling',);
  });

  test('every top-level asset directory on disk is declared in pubspec', () {
    final dirs = Directory('assets')
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.replaceAll(r'\', '/'))
        .toList();
    for (final d in dirs) {
      // fonts/ is consumed via the fonts: section (plus two explicit OFL
      // entries), not an assets: directory include.
      if (d == 'assets/fonts') continue;
      expect(pubspec.contains('- $d/'), isTrue,
          reason: '$d exists on disk but pubspec never declares it — its '
              'files silently do not ship');
    }
  });
}
