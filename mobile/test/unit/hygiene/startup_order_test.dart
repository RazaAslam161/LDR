import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Startup ordering, asserted rather than remembered.
///
/// `SupabaseService.client` is a `static late final` assigned on the LAST line
/// of `init()`. Dart evaluates a `Future.wait` argument list eagerly, left to
/// right, and an `async` body runs synchronously only as far as its first
/// `await` — so anything placed beside `SupabaseService.init()` in that list
/// reads `client` before it is assigned and throws LateInitializationError.
///
/// `ReleaseGate.check()` sat in that list for thirty-odd builds. Its own
/// fail-open catch swallowed the error and logged "gate unreachable, allowing"
/// on every launch, so nothing ever surfaced: the min_build gate and the block
/// screen were dead the whole time, and a fleet that looked gated was not.
///
/// The failure is silent by construction. That is why it gets a test and not a
/// comment.
void main() {
  final source = File('lib/main.dart').readAsStringSync();

  // A comment that merely mentions `SupabaseService.client` is not a read, and
  // the explanation above that call site says the words out loud.
  String stripComments(String s) => s.split('\n').map((l) {
        final i = l.indexOf('//');
        return i == -1 ? l : l.substring(0, i);
      }).join('\n');

  final src = stripComments(source);

  /// The `Future.wait([...])` that `SupabaseService.init()` is a member of.
  String startupWait() {
    final anchor = src.indexOf('SupabaseService.init()');
    expect(anchor, greaterThan(-1),
        reason: 'main.dart no longer calls SupabaseService.init() — this file '
            'is asserting nothing until that is fixed.',);
    final open = src.lastIndexOf('Future.wait([', anchor);
    expect(open, greaterThan(-1),
        reason: 'SupabaseService.init() is no longer inside a Future.wait; '
            'retarget this test at whatever replaced it.',);
    var depth = 0;
    for (var i = src.indexOf('[', open); i < src.length; i++) {
      if (src[i] == '[') depth++;
      if (src[i] == ']') {
        depth--;
        if (depth == 0) return src.substring(open, i);
      }
    }
    fail('unterminated Future.wait around SupabaseService.init()');
  }

  test('the release gate does not share a Future.wait with the client it reads',
      () {
    expect(startupWait().contains('ReleaseGate.check'), isFalse,
        reason: 'ReleaseGate.check() reads SupabaseService.client as the first '
            'thing in its try. Beside init() in the same Future.wait it throws '
            'LateInitializationError into its own fail-open catch on every '
            'launch — silently, forever. Await it below the group instead.',);
  });

  test('the release gate is awaited before the first frame', () {
    // MilesApp.build reads ReleaseGate.isBlocked, and _blocked is a plain
    // static with no listenable — a check that lands after runApp leaves the
    // first frame ungated with nothing to rebuild it.
    expect(RegExp(r'await[^;]*ReleaseGate\.check\(\)').hasMatch(src), isTrue,
        reason: 'ReleaseGate.check() must be awaited, not fire-and-forget.',);
    expect(src.indexOf('ReleaseGate.check()'),
        lessThan(src.indexOf('runApp(')),
        reason: 'ReleaseGate.check() must complete before runApp().',);
  });

  test('nothing in the startup Future.wait reads the client it races', () {
    // Each class's own body, keyed by name. Per class rather than per file
    // because diag.dart holds both Diag, which is innocent, and ErrorReporter,
    // which does read the client — sharing a file is not sharing a call graph.
    final bodyOf = <String, String>{};
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final text = stripComments(f.readAsStringSync());
      for (final m
          in RegExp(r'^(?:abstract )?class (\w+)', multiLine: true)
              .allMatches(text)) {
        final open = text.indexOf('{', m.end);
        if (open == -1) continue;
        var depth = 0;
        for (var i = open; i < text.length; i++) {
          if (text[i] == '{') depth++;
          if (text[i] == '}') {
            depth--;
            if (depth == 0) {
              bodyOf[m.group(1)!] = text.substring(open, i);
              break;
            }
          }
        }
      }
    }

    const reads = [
      'SupabaseService.client',
      'SupabaseService.currentUserId',
      'SupabaseService.authChanges',
      'Supabase.instance',
    ];

    final checked = <String>[];
    final guilty = <String>[];
    for (final m
        in RegExp(r'([A-Z]\w*)\.\w+\(').allMatches(startupWait())) {
      final owner = m.group(1)!;
      // init() is where client comes from; it is allowed to know about it.
      if (owner == 'SupabaseService') continue;
      final body = bodyOf[owner];
      if (body == null) continue; // declared in a package, not ours to police
      checked.add(owner);
      if (reads.any(body.contains)) guilty.add(owner);
    }

    // Without this the test passes by resolving nothing — a renamed class or a
    // moved file would read as a clean startup path.
    expect(checked.length, greaterThanOrEqualTo(3),
        reason: 'only resolved $checked from the startup Future.wait; the '
            'class-to-file map is broken, not the startup path.',);
    expect(guilty, isEmpty,
        reason: 'these run beside SupabaseService.init() and touch the client '
            'it has not assigned yet — LateInitializationError, swallowed by '
            'whatever catch they happen to have: ${guilty.join(', ')}',);
  });
}
