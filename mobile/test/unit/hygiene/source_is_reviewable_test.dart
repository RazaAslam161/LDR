import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A source file git treats as BINARY cannot be reviewed.
///
/// One NUL byte anywhere in the first 8 KB is enough: git stops producing a
/// diff for the file and prints `Bin 0 -> N bytes` instead, so the change lands
/// with nobody able to read it — on a repo where several sessions edit the same
/// tree and review IS the safety net.
///
/// This exists because it happened. `kReactionMore` was written as a sentinel
/// beginning with a literal NUL; every test passed, `flutter analyze` was clean,
/// and `reaction_bar.dart` staged as `Bin 0 -> 11398 bytes`. Nothing else in the
/// toolchain has an opinion about it — the analyzer reads UTF-8 happily and a
/// NUL in a string constant is valid Dart.
///
/// A control character that has to survive in a string belongs in an escape
/// sequence, never as a raw byte. message_seal_test.dart already says so in
/// a comment; this is the same rule with something enforcing it -- and the
/// first thing it caught was this file, whose own comment had quoted the
/// escape literally.
void main() {
  test('no Dart source is binary to git', () {
    final offenders = <String>[];
    for (final dir in ['lib', 'test', 'tool']) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (f.readAsBytesSync().contains(0)) offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'a raw NUL makes git treat the whole file as binary, so it '
            'commits with no diff: $offenders',);
  });
}
