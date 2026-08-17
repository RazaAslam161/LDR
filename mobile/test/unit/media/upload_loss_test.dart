import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Three ways this app lost media evidence, pinned at the source.
///
/// Each one had the same shape — the failure happened, code caught it, and
/// nothing downstream could tell: a body-photo upload folded into the same
/// null as "signed out", a gallery batch that reported failures one anonymous
/// snackbar at a time and dropped the files, and a video-init diagnostic sent
/// through Diag.record, which has been compile-time off in every shipped
/// build since 10. The compiler cannot see any of these regressing, so the
/// shapes are asserted here the way the hygiene suite does it.
void main() {
  /// [path] with comment lines removed. The bans below are on doing the thing,
  /// not on naming it — the comments that explain WHY these paths changed are
  /// exactly where the banned spellings get mentioned.
  String code(String path) => File(path)
      .readAsStringSync()
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('the method-body walker still walks', () {
    // A detector that cannot find anything reports every rule as obeyed.
    expect(_methodBody('void f() { if (x) { y(); } }', 'f'),
        '{ if (x) { y(); } }',);
    expect(_methodBody('void f() { }', 'missing'), isNull);
  });

  test('uploadBodyPhoto rethrows — no catch folding failure into null', () {
    final body = _methodBody(
      code('lib/features/touch_map/touch_map_repository.dart'),
      'uploadBodyPhoto',
    );
    expect(body, isNotNull,
        reason: 'uploadBodyPhoto not found — renamed without moving this?',);
    expect(body, isNot(contains('catch')),
        reason: 'a failed body-photo upload must throw to the screen; a catch '
            'here returns the same null as "signed out" and the spinner just '
            'stops',);
  });

  test('the body-photo screen surfaces a failed upload with Retry', () {
    final src = code('lib/features/touch_map/touch_map_screen.dart');
    expect(src, contains("That photo didn't upload."),
        reason: 'the upload can throw now; the screen must say so',);
    expect(src, contains("ErrorReporter.report(e, st, kind: 'touch')"),
        reason: 'an upload failure only one of two handsets can see must also '
            'reach client_errors',);
  });

  test('gallery upload failures are reported, counted, and retryable', () {
    final src = code('lib/features/gallery/gallery_screen.dart');
    expect(src, contains("ErrorReporter.report(e, st, kind: 'gallery')"),
        reason: 'a swallowed gallery upload failure is invisible to the fleet',);
    expect(src, contains("SnackBarAction(label: 'Retry'"),
        reason: 'a failure the user cannot act on is a notice, not a remedy',);
    expect(src, isNot(contains("One picture didn't upload.")),
        reason: 'the per-failure snackbar named no picture and offered no '
            'retry — failures are counted and kept as tiles now',);
  });

  test('video init failures report through ErrorReporter, not the dead ring',
      () {
    final src = code('lib/features/chat/widgets/video_surface.dart');
    expect(src, isNot(contains('Diag.record')),
        reason: 'Diag.record is compile-time off in every shipped build; an '
            'event routed through it can never reach client_errors',);
    expect(src, contains("ErrorReporter.report(e, st, kind: 'video-init')"));
    // The old fields map sent e.toString(), which for a network video can
    // carry the signed URL. ErrorReporter discards exception text by design;
    // nothing in this file may hand it somewhere that does not.
    expect(src, isNot(contains('e.toString()')));
  });
}

/// The body of [name]'s method in [src] — the first brace after the signature
/// through its balanced close. Interpolation braces balance themselves, so a
/// plain count is enough for the files this walks.
String? _methodBody(String src, String name) {
  final at = src.indexOf('$name(');
  if (at < 0) return null;
  final open = src.indexOf('{', at);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') depth--;
    if (depth == 0) return src.substring(open, i + 1);
  }
  return null;
}
