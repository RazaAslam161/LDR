import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The repository's shape, asserted rather than remembered.
///
/// This exists because the repo had drifted into three products in one folder:
/// a dead Next.js prototype with its own package.json, tsconfig, tailwind and
/// eslint config at the root; 2.3GB of build artefacts beside them; a README
/// describing a web app with Stripe and a revenue goal, none of which was ever
/// true of the thing that ships; and six loose Markdown files, one of them a
/// second ROADMAP.
///
/// None of that was a bug and all of it cost time — the first file a person
/// opens was the most misleading one in the tree. A rule nobody can check is a
/// rule that decays, so the rules live here.
void main() {
  final root = Directory('..');

  List<String> tracked() {
    final r = Process.runSync('git', ['ls-files'], workingDirectory: '..');
    return (r.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  test('the repository root holds nothing but the entry point', () {
    // Everything else belongs to a directory that says what it is. A file here
    // is one a newcomer reads first, so the root is the one place worth
    // policing absolutely.
    const allowed = {'README.md', '.gitignore'};
    final all = tracked();
    // Without this the whole file passes by listing nothing — git resolving to
    // the wrong directory would read as a spotless repository.
    expect(all.length, greaterThan(100),
        reason: 'git ls-files returned almost nothing; these checks are blind',);
    final loose = all.where((f) => !f.contains('/')).toSet()..removeAll(allowed);
    expect(loose, isEmpty,
        reason: 'put it in mobile/, supabase/, scripts/ or docs/: $loose',);
  });

  test('no build artefact is tracked', () {
    // 2.3GB of APKs accumulated beside the source. They are regenerable by
    // definition, so the only thing committing one achieves is a repository
    // nobody can clone.
    final artefacts = tracked()
        .where((f) => RegExp(r'\.(apk|aab|ipa|jar|so|zip)$').hasMatch(f))
        .toList();
    expect(artefacts, isEmpty, reason: 'build output is not source: $artefacts');
  });

  test('only one product stack is configured at the root', () {
    // The Next.js prototype had exactly one commit, was 47 days stale, and had
    // been superseded by the Flutter app — but its config sat at the root
    // implying the repo was a web project. Two stacks in one root is a question
    // every newcomer has to answer for themselves.
    const foreign = [
      'package.json',
      'tsconfig.json',
      'next.config.js',
      'tailwind.config.ts',
      'postcss.config.js',
      '.eslintrc.json',
    ];
    final present = foreign.where((f) => File('../$f').existsSync()).toList();
    expect(present, isEmpty,
        reason: 'this repository ships a Flutter app: $present',);
  });

  test('.env.example documents every key the app actually reads', () {
    // The one form of documentation rot that stops a new machine from
    // building at all, and it is silent: config.dart throws a StateError
    // before the first frame when a key is missing, naming the constant rather
    // than what to put in it.
    final config = File('lib/core/app/config.dart').readAsStringSync();
    final example = File('.env.example').readAsStringSync();
    final keys = RegExp(r"static const \w*Key\w* = '([A-Z0-9_]+)'")
        .allMatches(config)
        .map((m) => m[1]!)
        .toSet();

    expect(keys, isNotEmpty, reason: 'no env keys parsed out of config.dart');
    final undocumented = keys.where((k) => !example.contains(k)).toList();
    expect(undocumented, isEmpty,
        reason: 'read by config.dart, absent from .env.example: $undocumented',);
  });

  test('documentation is filed, not loose', () {
    // Six Markdown files at the root, two of them roadmaps, none of them
    // dated. Current work belongs in docs/, superseded work in docs/archive/,
    // and the distinction has to be visible from the path alone.
    final docs = tracked().where((f) => f.startsWith('docs/')).toList();
    expect(docs, isNotEmpty);
    final atDocsRoot =
        docs.where((f) => f.split('/').length == 2).map((f) => f).toList();
    // A small, deliberate set: the index-level documents. Everything else must
    // be under architecture/, guides/ or archive/.
    const allowedAtDocsRoot = {'docs/REFERENCE.md', 'docs/FIELD-TEST.md'};
    expect(atDocsRoot.toSet().difference(allowedAtDocsRoot), isEmpty,
        reason: 'file it under docs/architecture, docs/guides or docs/archive: '
            '${atDocsRoot.toSet().difference(allowedAtDocsRoot)}',);
    expect(Directory('../docs/archive').existsSync(), isTrue);
  });

  group('zero dead code', () {
    List<File> dartIn(String dir) => Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('every file under lib/ is reachable from another file', () {
      // Two were not: an unused RepositoryException, and an FcmTodo stub whose
      // doc comment still said "there's no Firebase project yet" long after
      // push went live and was verified end to end. Dead code does not just sit
      // there — it actively misinforms whoever reads it next.
      final files = dartIn('lib');
      expect(files.length, greaterThan(100), reason: 'lib/ did not enumerate');
      final sources = {for (final f in files) f.path: f.readAsStringSync()};

      final orphans = <String>[];
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        if (name == 'main.dart') continue;
        final rel = f.path.replaceAll(r'\', '/').split('lib/').last;
        final referenced = sources.entries.any((e) =>
            e.key != f.path &&
            (e.value.contains(rel) || e.value.contains("'$name")),);
        if (!referenced) orphans.add(rel);
      }
      expect(orphans, isEmpty,
          reason: 'imported by nothing — delete it, or move a real script to '
              'tool/: $orphans',);
    });

    test('no code is commented out', () {
      // Git remembers. A commented-out line is a claim that something might
      // come back, and it never does.
      //
      // Two discriminators, both learned from false positives while writing
      // this: real code ends in a statement terminator where prose wraps
      // mid-sentence, and Dart never puts a space before '(' because dartfmt
      // removes it — so "// _openMedia (permissions, camera in use)" is a
      // sentence, not a call.
      final code = RegExp(r'^\s*//\s*('
          r'(?:await|return|final|const|var|if|for|while|throw|import|print|debugPrint)\b'
          r'|[A-Za-z_]\w*\('
          r'|[A-Za-z_]\w*\s*=[^=]'
          r'|[A-Za-z_][\w.]*\.[A-Za-z_]\w*\('
          ')');
      final terminator = RegExp(r'[;{},]\s*$');

      bool isCommentedCode(String line) {
        final s = line.trim();
        if (!s.startsWith('//') || s.startsWith('///')) return false;
        return code.hasMatch(line) && terminator.hasMatch(s.substring(2).trim());
      }

      // The check is worthless if it cannot recognise the thing it forbids.
      expect(isCommentedCode('      // await _pc!.setRemoteDescription(o);'),
          isTrue,
          reason: 'the detector no longer detects anything',);
      expect(isCommentedCode('      // it covers _openMedia and _routeAudio,'),
          isFalse,
          reason: 'the detector flags ordinary prose',);

      final hits = <String>[];
      for (final f in dartIn('lib')) {
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (isCommentedCode(lines[i])) {
            hits.add('${f.uri.pathSegments.last}:${i + 1}');
          }
        }
      }
      expect(hits, isEmpty, reason: 'delete it; git has it: $hits');
    });

    test('every declared dependency is actually used', () {
      // `collection` sat in pubspec.yaml imported by nothing. A dependency is a
      // supply-chain entry, a version constraint and a line of the resolve — it
      // should have to earn its place.
      final spec = File('pubspec.yaml').readAsStringSync();
      final deps = RegExp('^dependencies:(.*?)^dev_dependencies:',
              dotAll: true, multiLine: true,)
          .firstMatch(spec)
          ?.group(1);
      expect(deps, isNotNull, reason: 'could not parse the dependencies block');

      final names = RegExp('^  ([a-z0-9_]+):', multiLine: true)
          .allMatches(deps!)
          .map((m) => m[1]!)
          .where((n) => n != 'flutter')
          .toSet();
      expect(names.length, greaterThan(20), reason: 'dependency parse failed');

      final dart = dartIn('lib').map((f) => f.readAsStringSync()).join('\n');
      // A package can be used without a Dart import: a lint set is included by
      // analysis_options, and an icon font is referenced from pubspec itself.
      final other = File('analysis_options.yaml').readAsStringSync() + spec;

      final unused = names
          .where((n) => !dart.contains('package:$n') && !other.contains(n))
          .toList()
        ..sort();
      expect(unused, isEmpty, reason: 'declared but never used: $unused');
    });
  });

  test('the analyzer reports no errors and no warnings', () {
    // Worth the ~40s it costs, because this was measured wrong for a whole
    // session: the grep used to check it required leading whitespace, and the
    // analyzer prints `warning - ...` flush left while only indenting `info`.
    // Seven real warnings sat behind a green-looking check — an always-true
    // type guard, an unused import, a raw Map, two uninferrable constructors
    // and one use of a package-internal member. A verification that cannot
    // fail is worse than no verification, because it is trusted.
    final r = Process.runSync('flutter', ['analyze', '--no-pub'],
        runInShell: true,);
    final out = '${r.stdout}';
    final errors =
        RegExp('^error - ', multiLine: true).allMatches(out).length;
    final warnings =
        RegExp('^warning - ', multiLine: true).allMatches(out).length;

    // Proves the output was actually parsed. `info` lines always exist here;
    // zero of them means analyze did not run and the counts above are noise.
    expect(RegExp('^ *info - ', multiLine: true).hasMatch(out), isTrue,
        reason: 'could not read analyzer output — this check is blind',);

    expect(errors, 0, reason: 'analyzer errors:\n$out');
    expect(warnings, 0, reason: 'analyzer warnings:\n$out');
  }, timeout: const Timeout(Duration(minutes: 4)),);

  test('analyzer suppressions stay countable', () {
    // An `// ignore:` is a warning someone decided to keep. That can be the
    // right call — the one here guards a package-internal reconnect that only
    // a two-phone test could safely replace — but it has to stay a decision
    // rather than a habit, so adding one means deliberately moving this number.
    final ignores = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .expand((f) => f
            .readAsStringSync()
            .split('\n')
            .where((l) => l.contains('// ignore:'))
            .map((l) => '${f.uri.pathSegments.last}: ${l.trim()}'),)
        .toList();
    expect(ignores.length, lessThanOrEqualTo(1),
        reason: 'each suppression needs a reason in a comment above it, and '
            'this bound moved on purpose: $ignores',);
  });

  test('every source path a test names actually exists', () {
    // Several tests assert on source text rather than behaviour, by reading a
    // file path. Those paths are invisible to the compiler and to a rename: a
    // restructure moved five files and two suites broke — one of them this one.
    // Worse is the silent case, where a path that no longer exists is read
    // inside a try or an orElse and the assertion quietly stops checking
    // anything.
    final referenced = <String>{};
    for (final f in Directory('test')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"'((?:lib|\.\./supabase)/[\w./-]+\.\w+)'")
          .allMatches(f.readAsStringSync())) {
        referenced.add(m[1]!);
      }
    }
    expect(referenced, isNotEmpty, reason: 'no source paths parsed from tests');
    final missing = referenced.where((p) => !File(p).existsSync()).toList()
      ..sort();
    expect(missing, isEmpty,
        reason: 'a test reads a file that no longer exists: $missing');
  });

  group('no glassmorphism', () {
    List<File> lib() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('nothing blurs what is behind it', () {
      // BackdropFilter is the expensive half: the compositor reads back
      // everything already painted behind the widget and blurs it, every
      // frame, scaling with both sigma and area — on top of an animated
      // background, on the cheap phones this has to stay smooth on.
      //
      // The camera's own filter preview is not this. It blurs an image it is
      // given, not the screen behind it.
      final offenders = <String>[];
      for (final f in lib()) {
        if (f.path.endsWith('camera_filter_painter.dart')) continue;
        for (final line in f.readAsStringSync().split('\n')) {
          final s = line.trim();
          if (s.startsWith('//') || s.startsWith('///')) continue;
          if (s.contains('BackdropFilter') || s.contains('ImageFilter.blur')) {
            offenders.add('${f.uri.pathSegments.last}: $s');
          }
        }
      }
      expect(offenders, isEmpty, reason: 'use an opaque surface: $offenders');
    });

    test('the vocabulary is gone, so the look cannot be reached for', () {
      // The blur was removed once already and the names outlived it —
      // glassDecoration(), milesBlur(), four blur sigmas, a _GlassBar that had
      // been opaque for months. A name is an invitation: the next person reads
      // _GlassBar, sees no blur, and helpfully adds one back.
      const banned = [
        'glassDecoration',
        'milesBlur',
        'surfaceGlass',
        'glassStrong',
        'glassSubtle',
        'glassEmber',
        'glassBorder',
        'blurSm',
        'blurMd',
        'blurLg',
        'blurXl',
      ];
      final found = <String>[];
      for (final f in lib()) {
        // Code only. Explaining in a comment why a thing was removed is how
        // the next person learns not to re-add it, so the ban is on using the
        // names, not on naming them.
        final code = f
            .readAsStringSync()
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final name in banned) {
          if (RegExp('\\b$name\\b').hasMatch(code)) {
            found.add('${f.uri.pathSegments.last}: $name');
          }
        }
      }
      expect(found, isEmpty, reason: 'removed with the blur: $found');
    });

    test('the surfaces you read text on are opaque', () {
      // The other half, and the one that survived: translucent panels over a
      // moving ember field. With the blur gone that is not frosted glass, it is
      // an animation playing behind your paragraph.
      // Only the surfaces text is read ON. A hairline border at 12% alpha is
      // an edge, not a window, and banning it would just push people to fake
      // one with a solid colour nobody picked.
      final theme = File('lib/core/ui/theme.dart').readAsStringSync();
      final translucent = RegExp(
              r'(fillColor|backgroundColor):\s*MilesColors\.\w+'
              r'\.withValues\(alpha:')
          .allMatches(theme)
          .map((m) => m[0]!)
          .toList();
      expect(theme, contains('fillColor'),
          reason: 'the theme no longer parses the way this check assumes');
      expect(translucent, isEmpty,
          reason: 'a surface text is read on is see-through: $translucent');
    });
  });

  test('the launcher disguise is intact', () {
    // Not cleanup-adjacent, deliberately. The label looks like a placeholder
    // somebody forgot to change, which is exactly why a well-meaning tidy-up
    // would "fix" it and quietly undo the app's whole threat model.
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:label="News"'),
        reason: 'the launcher name is a disguise and is intentional',);
    expect(root.existsSync(), isTrue);
  });
}
