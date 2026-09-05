import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One open bracket while walking a source file: what it was called, and the
/// span it turned out to cover.
class _Call {
  _Call(this.name, this.start);
  final String name;
  final int start;
  int end = 0;
}

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

  test('the .env that ships in the APK holds nothing the app does not read',
      () {
    // The other direction of the test above, and the one a reviewer cannot
    // perform. pubspec.yaml lists `.env` as an asset, so it is packed into
    // assets/flutter_assets/.env in plaintext and a sideloaded APK is a zip
    // anyone can open — while .gitignore keeps the file out of the tree, so
    // nothing in code review ever sees what it contains.
    //
    // That combination has already published credentials once: METERED_TURN_*
    // and GIPHY_API_KEY both sat in here after their consumers were removed.
    // The allowed set is derived from config.dart rather than written down, so
    // a genuinely new public key needs no edit here — but a name the app never
    // reads cannot ride along to every handset unnoticed.
    final env = File('.env');
    if (!env.existsSync()) {
      // Absent on a clean checkout by design, and CI writes its placeholder
      // only just before `flutter analyze`. Nothing to assert.
      return;
    }
    final config = File('lib/core/app/config.dart').readAsStringSync();
    final declared = RegExp(r"static const \w*Key\w* = '([A-Z0-9_]+)'")
        .allMatches(config)
        .map((m) => m[1]!)
        .toSet();
    // Plus the names gates.yml writes when no .env is present: the same two
    // public values, unprefixed, from before the NEXT_PUBLIC_ names.
    final allowed = {...declared, 'SUPABASE_URL', 'SUPABASE_ANON_KEY'};

    final present = env
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#') && l.contains('='))
        .map((l) => l.split('=').first.trim())
        .toSet();

    final unexpected = present.difference(allowed).toList()..sort();
    expect(unexpected, isEmpty,
        reason: 'these ship in the APK in plaintext and nothing reads them; '
            'a value that must stay revocable belongs in app_secrets behind '
            'an edge function: $unexpected',);
  });

  test('.env is never tracked', () {
    // The whole argument above rests on it staying out of git. If it is ever
    // committed the secret is already published, and the test that reads the
    // working copy would start passing on everyone's machine at once.
    expect(tracked().where((f) => f == 'mobile/.env' || f == '.env'), isEmpty,
        reason: '.env is bundled into the APK and must stay untracked',);
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
        reason: 'file it under docs/guides or docs/archive: '
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
    // Worth the ~40s it costs, because this was measured wrong twice.
    //
    // First the grep required leading whitespace, and seven real warnings sat
    // behind a green-looking check. The fix anchored both counts flush left —
    // which repaired `warning` and quietly broke `error`.
    //
    // The analyzer right-aligns the severity to width 7, so the indent differs
    // per level and no single flush-left anchor can match them all:
    //   `warning - `   0 spaces
    //   `  error - `   2 spaces
    //   `   info - `   3 spaces
    // `^error - ` therefore never matched, and the error count — the one this
    // test exists to keep at zero — was structurally pinned to 0 while the
    // `^ *info - ` probe below went on reporting the check healthy.
    //
    // Leading whitespace is optional in all three now. A verification that
    // cannot fail is worse than no verification, because it is trusted.
    // Retried once, for the same reason release.sh and gates.yml retry: a
    // cold analysis server can answer with nothing at all, and on a fresh CI
    // runner the first `flutter analyze` is always cold. The first run that
    // ever reached this test on GitHub (2026-09-02, b5907c0) failed exactly
    // here with an empty capture while the workflow's own analyze step — which
    // retries — had passed a minute earlier. Still fails closed on two empty
    // answers, and the failure now carries what came back rather than the
    // word "blind".
    var out = '';
    var err = '';
    var code = -1;
    for (var attempt = 1; attempt <= 2; attempt++) {
      final r = Process.runSync('flutter', ['analyze', '--no-pub'],
          runInShell: true,);
      out = '${r.stdout}';
      err = '${r.stderr}';
      code = r.exitCode;
      // The summary goes to stdout on Windows and to stderr on Linux.
      if (RegExp('issues? found').hasMatch('$out$err')) break;
    }
    // `[-•]`, not ` - `: the Flutter tool separates fields with `-` on
    // Windows and `•` everywhere else. The first CI run to reach this test
    // (2026-09-02) captured 37 KB of `   info • ...` lines and matched none
    // of them, so on Linux all three counts below were structurally zero —
    // the §58 class again, one platform over.
    final errorLine = RegExp('^ *error [-•] ', multiLine: true);
    final warningLine = RegExp('^ *warning [-•] ', multiLine: true);
    final infoLine = RegExp('^ *info [-•] ', multiLine: true);
    // The detector has to recognise both shapes, or it is trusted for nothing.
    expect(errorLine.hasMatch('  error • x • f.dart:1:1 • r'), isTrue);
    expect(errorLine.hasMatch('  error - x - f.dart:1:1 - r'), isTrue);
    expect(infoLine.hasMatch('   info • x • f.dart:1:1 • r'), isTrue);

    final errors = errorLine.allMatches(out).length;
    final warnings = warningLine.allMatches(out).length;

    // Proves the output was actually parsed. `info` lines always exist here;
    // zero of them means analyze did not run and the counts above are noise.
    expect(infoLine.hasMatch(out), isTrue,
        reason: 'could not read analyzer output — this check is blind '
            '(exit $code, ${out.length} bytes of stdout, stderr: '
            '${err.trim()}; stdout tail: '
            '${out.length > 600 ? out.substring(out.length - 600) : out})',);

    expect(errors, 0, reason: 'analyzer errors:\n$out');
    expect(warnings, 0, reason: 'analyzer warnings:\n$out');
  }, timeout: const Timeout(Duration(minutes: 4)),);

  test('analyzer suppressions stay countable', () {
    // An `// ignore:` is a warning someone decided to keep. That can be the
    // right call — the one here guards a package-internal reconnect that only
    // a two-phone test could safely replace — but it has to stay a decision
    // rather than a habit, so adding one means deliberately moving this number.
    //
    // Moved 1 -> 3 for the rejoin retry: realtime_client reports a refused join
    // through the caller's callback only, leaving the channel in `joining` with
    // nothing scheduled, and `isJoined` is the only probe that tells the two
    // apart. It is @internal, so reading it is the price of noticing.
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
    // 3 -> 4 on 2026-08-30: logging.dart's `avoid_print` — `print` is the one
    // channel silenceLogsInRelease() cannot null, and share telemetry must
    // survive a release build (BRAIN §220: five builds of field tests ran
    // blind on debugPrint-based instrumentation).
    expect(ignores.length, lessThanOrEqualTo(4),
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

    /// [src] with every comment and string literal replaced by spaces of the
    /// same length, so offsets still line up with the original. The paren walk
    /// below counts brackets, and both a `(` inside a sentence and a
    /// commented-out widget will unbalance it — which does not throw, it
    /// silently attributes every later match to the wrong constructor.
    String mask(String src) {
      final b = StringBuffer();
      var i = 0;
      while (i < src.length) {
        final two = i + 1 < src.length ? src.substring(i, i + 2) : '';
        if (two == '//') {
          while (i < src.length && src[i] != '\n') {
            b.write(' ');
            i++;
          }
        } else if (two == '/*') {
          b.write('  ');
          i += 2;
          while (i < src.length &&
              !(i + 1 < src.length && src.substring(i, i + 2) == '*/')) {
            b.write(src[i] == '\n' ? '\n' : ' ');
            i++;
          }
          if (i < src.length) {
            b.write('  ');
            i += 2;
          }
        } else if (src[i] == "'" || src[i] == '"') {
          final q = src.startsWith(src[i] * 3, i) ? src[i] * 3 : src[i];
          b.write(' ' * q.length);
          i += q.length;
          while (i < src.length && !src.startsWith(q, i)) {
            if (src[i] == r'\' && i + 2 < src.length) {
              b.write('  ');
              i += 2;
              continue;
            }
            b.write(src[i] == '\n' ? '\n' : ' ');
            i++;
          }
          if (i < src.length) {
            b.write(' ' * q.length);
            i += q.length;
          }
        } else {
          b.write(src[i]);
          i++;
        }
      }
      return b.toString();
    }

    /// For each offset in [at], the call whose argument list encloses it and
    /// the call enclosing that one. `color:` means an edge inside
    /// `Border.all(...)`, a shadow inside `BoxShadow(...)` and a fill inside
    /// `BoxDecoration(...)`; nothing but the enclosing call distinguishes them.
    Map<int, List<_Call?>> callsAround(String masked, List<int> at) {
      final out = <int, List<_Call?>>{};
      final open = <_Call>[];
      // The trailing `<...>` matters: half these calls are generic —
      // showModalBottomSheet<String>, showDialog<bool> — and without it the
      // name comes back empty and the call is attributed to nothing.
      final ident = RegExp(r'([A-Za-z_][\w.]*)\s*(<[^<>()]*>)?\s*$');
      _Call? nthOpen(int back) =>
          open.length > back ? open[open.length - 1 - back] : null;
      var next = 0;
      for (var i = 0; i < masked.length; i++) {
        while (next < at.length && at[next] <= i) {
          out[at[next]] = [nthOpen(0), nthOpen(1)];
          next++;
        }
        final c = masked[i];
        if (c == '(' || c == '[' || c == '{') {
          final from = i < 80 ? 0 : i - 80;
          final named = c != '('
              ? ''
              : ident.firstMatch(masked.substring(from, i))?.group(1) ?? '';
          open.add(_Call(named, i));
        } else if ((c == ')' || c == ']' || c == '}') && open.isNotEmpty) {
          open.removeLast().end = i;
        }
      }
      for (final c in open) {
        c.end = masked.length;
      }
      for (; next < at.length; next++) {
        out[at[next]] = [null, null];
      }
      return out;
    }

    /// Widgets that paint a fill themselves, and the decoration objects that
    /// describe one for the widget above them.
    const paints = {
      'Container',
      'ColoredBox',
      'DecoratedBox',
      'Material',
      'Card',
      'Ink',
      // This app's own panel. Its default is opaque, but the `color:` it
      // accepts paints the same full-bleed fill as any of the above.
      'SurfacePanel',
    };
    const describes = {'BoxDecoration', 'ShapeDecoration'};
    final holdsContent = RegExp(r'\bchild(ren)?\s*:');
    // withValues/withOpacity, an ARGB literal whose alpha byte is not FF,
    // or one of Material's pre-diluted constants — Colors.black54 is a
    // wash with a friendlier name, and leaving it out would put this rule
    // one find-and-replace away from meaning nothing.
    final seeThrough = RegExp(r'\b(color|backgroundColor|fillColor)\s*:'
        r'\s*[^,;]*?(\.withValues\s*\(\s*alpha:|\.withOpacity\s*\(|'
        r'Color\s*\(\s*0x(?!(FF|ff))[0-9a-fA-F]{2}|'
        r'Colors\.(black|white)\d)');
    // Legibility over imagery nobody controls genuinely needs translucency.
    // The exemption has to name what is behind it — "scrim" alone is a shrug.
    final overImagery = RegExp(r'//.*\bscrim over \w');

    /// Surfaces that float above a page and carry text you act on. Their
    /// backdrop is whatever the page was showing, which on this app is moving.
    const modalSurfaces = {
      'AlertDialog',
      'Dialog',
      'SimpleDialog',
      'showModalBottomSheet',
      'showBottomSheet',
      'BottomSheet',
      'Drawer',
      'NavigationDrawer',
      'showMenu',
      'PopupMenuButton',
      'DropdownMenu',
      'MenuAnchor',
      'SnackBar',
    };
    // Deliberately not surfaceTintColor: setting THAT transparent is how M3 is
    // told to stop tinting a fill by elevation, and is the fix, not the fault.
    final nakedFill =
        RegExp(r'\b(color|backgroundColor)\s*:\s*Colors\.transparent\b');

    List<String> glassIn(String src, String label) {
      final masked = mask(src);
      // Any drift here shifts every offset and quietly points the whole check
      // at the wrong constructors.
      expect(masked.length, src.length, reason: 'mask() moved $label');
      final hits = seeThrough.allMatches(masked).toList();
      if (hits.isEmpty) return const [];
      final around = callsAround(masked, hits.map((m) => m.start).toList());
      final lines = src.split('\n');

      final found = <String>[];
      for (final m in hits) {
        final owner = around[m.start]![0];
        final name = owner?.name ?? '';
        final key = m[1]!;

        // Which call actually paints this fill — the one holding the property,
        // or the widget the decoration belongs to.
        final _Call? painter;
        if (key != 'color') {
          painter = owner; // backgroundColor / fillColor is always a surface
        } else if (describes.contains(name)) {
          painter = around[m.start]![1];
        } else if (paints.contains(name)) {
          painter = owner;
        } else {
          continue; // an edge, a shadow, an icon, a letterform
        }

        // A fill with nothing on it is a rule, a dot, a halo or a swatch — not
        // a surface anyone reads.
        if (key == 'color' &&
            painter != null &&
            !holdsContent.hasMatch(masked.substring(painter.start, painter.end))) {
          continue;
        }

        // The whole comment block above the property, not just the line
        // directly above it: an explanation worth writing runs to three or
        // four lines, and the phrase lands on the first of them.
        final n = '\n'.allMatches(src.substring(0, m.start)).length;
        var explained = overImagery.hasMatch(lines[n]);
        for (var k = n - 1; k >= 0 && lines[k].trimLeft().startsWith('//');
            k--) {
          explained = explained || overImagery.hasMatch(lines[k]);
        }
        if (explained) continue;
        found.add('$label:${n + 1}  ${lines[n].trim()}');
      }
      return found;
    }

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
      //
      // This check used to read lib/core/ui/theme.dart and nothing else, so it
      // went green twice while 65 translucent panels sat in lib/features. The
      // theme was never where the glass was.
      //
      // Alpha is not banned, because most alpha in this app is right: borders,
      // shadows, gradients, glows, a 2px rule, a dimmer behind a modal, and a
      // scrim that keeps a caption legible over a photograph nobody controls.
      // Banning it outright would only teach the next person to write
      // Color(0x99...) instead. What is banned is narrower and is the thing
      // that actually hurt: a SURFACE — a fill with content sitting on it —
      // that you can see the background through.
      final offenders = <String>[];
      for (final f in lib()) {
        offenders.addAll(glassIn(f.readAsStringSync(),
            f.path.replaceAll(r'\', '/'),),);
      }
      expect(offenders, isEmpty,
          reason: 'a surface content is read on is see-through. Resolve the '
              'tint against the surface it sits on — MilesColors.surface1 / '
              'surface2 / night, or MilesColors.tint() to keep an accent '
              'wash — or, if it genuinely sits over imagery, say so with a '
              '"// scrim over <what>" comment:\n${offenders.join('\n')}',);
    });

    /// Call sites in [src] that hand a modal surface's fill back to whatever
    /// is behind it.
    List<String> nakedModalIn(String src, String label) {
      final masked = mask(src);
      final hits = nakedFill.allMatches(masked).toList();
      if (hits.isEmpty) return const [];
      final around = callsAround(masked, hits.map((m) => m.start).toList());
      final lines = src.split('\n');
      final found = <String>[];
      for (final m in hits) {
        if (!modalSurfaces.contains(around[m.start]![0]?.name)) continue;
        final n = '\n'.allMatches(src.substring(0, m.start)).length;
        found.add('$label:${n + 1}  ${lines[n].trim()}');
      }
      return found;
    }

    test('no modal hands its fill back to the background', () {
      // The half of the look the first three sweeps could not see. Everything
      // above hunts for a translucent colour someone wrote down; this is a
      // surface that paints NOTHING, and it reached the owner's screen twice
      // over — as `AlertDialog(backgroundColor: Colors.transparent)` holding
      // "Delete for everyone", and as the sheet of the same name.
      //
      // Colors.transparent has none of the shapes the alpha regex matches: no
      // withValues, no ARGB literal, no Colors.black54. It is the most
      // see-through colour in Material and it was the one spelling nothing
      // checked for.
      //
      // Only modal surfaces. A transparent Scaffold or AppBar is how the
      // ember field shows through a PAGE, and is the whole point of the
      // design — but a dialog, a sheet, a menu or a drawer is something you
      // read on, and behind it that same field is just an animation playing
      // under the text.
      final offenders = <String>[];
      for (final f in lib()) {
        offenders.addAll(nakedModalIn(
            f.readAsStringSync(), f.path.replaceAll(r'\', '/'),),);
      }
      expect(offenders, isEmpty,
          reason: 'a modal surface paints nothing, so the animated background '
              'shows through it. Drop the override and let the theme fill it '
              '(dialogTheme / bottomSheetTheme / popupMenuTheme / drawerTheme '
              'are all opaque), or name a MilesColors fill:\n'
              '${offenders.join('\n')}',);
    });

    test('the naked-modal detector can tell a dialog from a page', () {
      String only(String src) => nakedModalIn(src, 'x').join('|');

      // The thing itself, in both spellings the owner actually hit.
      expect(
          only('AlertDialog(backgroundColor: Colors.transparent, '
              'title: Text(t))'),
          contains('x:1'),);
      expect(
          only('showModalBottomSheet<String>(context: context, '
              'backgroundColor: Colors.transparent, builder: b)'),
          contains('x:1'),);
      expect(only('Drawer(backgroundColor: Colors.transparent, child: c)'),
          contains('x:1'),);

      // Not the thing. A page is transparent so the ember field shows through
      // it, which is the design; and turning M3's elevation tint off is the
      // fix these rules are asking for, not a new offence.
      expect(only('Scaffold(backgroundColor: Colors.transparent, body: b)'),
          isEmpty,);
      expect(only('AppBarTheme(backgroundColor: Colors.transparent)'), isEmpty);
      expect(
          only('AlertDialog(surfaceTintColor: Colors.transparent, '
              'backgroundColor: MilesColors.surface1)'),
          isEmpty,);
      // A transparent NavigationBar sits inside SurfaceNavBar, which paints.
      expect(only('NavigationBar(backgroundColor: Colors.transparent)'),
          isEmpty,);
    });

    test('the glass detector can tell a panel from an edge', () {
      // A check that goes green after a cleanup proves nothing; it has to be
      // able to fail. Every line here is a distinction the rule turns on, and
      // each one was a false positive or a false negative while it was being
      // written.
      String only(String src) => glassIn(src, 'x').join('|');

      // The thing itself: a panel with content on it, see-through.
      expect(
          only('Container(decoration: BoxDecoration(color: '
              'C.withValues(alpha: 0.6)), child: Text(t))'),
          contains('x:1'),);
      // ...and reached the other way round, with a raw ARGB literal. If this
      // one is missed the ban is one search-and-replace from useless.
      expect(only('Material(color: Color(0x99120A0C), child: Text(t))'),
          contains('x:1'),);
      // ...or spelled the way Material spells it. Colors.black is a
      // colour; Colors.black54 is a hole in the panel.
      expect(only('Container(color: Colors.black54, child: Text(t))'),
          contains('x:1'),);
      expect(only('Container(color: Colors.black, child: Text(t))'),
          isEmpty,);

      // Not the thing: an edge, a shadow, a letterform, a 2px rule with
      // nothing on it, and a caption over a photograph that says so.
      expect(only('BoxDecoration(border: Border.all(color: '
          'C.withValues(alpha: 0.2)))'), isEmpty,);
      expect(only('BoxDecoration(boxShadow: [BoxShadow(color: '
          'C.withValues(alpha: 0.4))])'), isEmpty,);
      expect(only('Text(s, style: TextStyle(color: Color(0x99F5EFE6)))'),
          isEmpty,);
      expect(only('Container(height: 2, color: Color(0x33F5EFE6))'), isEmpty);
      expect(
          only('Container(color: Color(0x8C120A0C), // scrim over the map\n'
              '  child: Text(t),)'),
          isEmpty,);
      // The reason is usually longer than the line it sits above.
      expect(
          only('Container(\n  // A scrim over the map, because the label has\n'
              '  // to read against roads and water alike.\n'
              '  color: Color(0x8C120A0C),\n  child: Text(t),)'),
          isEmpty,);
      // The exemption has to name what is behind it, or it is just a way to
      // spell "ignore".
      expect(
          only('Container(color: Color(0x8C120A0C), // scrim\n'
              '  child: Text(t),)'),
          contains('x:1'),);

      // Commented-out and quoted code is not code. Both used to shift every
      // offset after them and mis-attribute the next real match.
      expect(only('// Container(color: Color(0x99120A0C), child: Text(t))'),
          isEmpty,);
      expect(only("Text(') (', style: TextStyle(color: C)); "
          'Container(decoration: BoxDecoration(color: '
          'C.withValues(alpha: 0.6)), child: Text(t))'), contains('x:1'),);
    });
  });

  test('every relay provider this function can offer is named in the policy',
      () {
    // A TURN relay carries the encrypted call media and sees both partners' IP
    // addresses. Adding one is a change to who receives user data, so it may
    // not happen quietly.
    //
    // A dormant Metered provider used to sit in this function, appended the
    // moment three METERED_TURN_* rows appeared in app_secrets - three INSERTs,
    // no release, no review, no document change. It was removed 2026-09-03
    // (BRAIN 267). This law is what stops the next one arriving the same way:
    // add a provider and the build fails until the privacy policy names it.
    final fn = File('../supabase/functions/turn-credentials/index.ts')
        .readAsStringSync();
    // Comments stripped first, and that is load-bearing rather than tidy: the
    // comment standing where the Metered branch used to be names
    // METERED_TURN_* itself, so a raw scan would match its own tombstone and
    // fail for ever.
    final code = fn
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'//.*$'), ''))
        .join('\n');

    // TWO nets, because either alone fails open.
    //
    // (a) Shape. Exactly one thing produces relay entries: Cloudflare's
    //     response, normalised. Nothing appends to it and no relay URI is
    //     written by hand. A provider added as TWILIO_ICE_USERNAME or as a
    //     literal turn: URL is invisible to the *_TURN_* scan below, and the
    //     prefix set can never be empty while CF_TURN_* exists - so the scan
    //     alone would fail open for ever.
    expect(code.contains('iceServers.push'), isFalse,
        reason: 'something appends relay entries to the Cloudflare response. '
            'A relay carries call media and sees both partners IP addresses: '
            'name the provider in section 4 of web/privacy-policy.html and '
            'add it to the map in this test, in the same change.',);
    expect(RegExp('''["'`]turns?:''').hasMatch(code), isFalse,
        reason: 'a turn:/turns: URI is written directly in this function, so a '
            'relay is being offered that did not come from Cloudflare. Declare '
            'it as above.',);

    // (b) Naming. Every provider reached through an upper-case secret key.
    final prefixes = RegExp(r'\b([A-Z][A-Z0-9]*)_TURN_[A-Z_]+\b')
        .allMatches(code)
        .map((m) => m.group(1)!)
        .toSet();
    expect(prefixes, isNotEmpty,
        reason: 'no *_TURN_* secret found at all - either the function stopped '
            'serving relays or this matcher has gone blind. Both need a '
            'human.',);

    const named = <String, String>{'CF': 'Cloudflare'};
    final policy =
        File('../web/privacy-policy.html').readAsStringSync();
    for (final p in prefixes) {
      final company = named[p];
      expect(company, isNotNull,
          reason: 'turn-credentials can offer a relay from an unrecognised '
              'provider ($p). Add it to this map AND give it a row in section '
              '4 of web/privacy-policy.html: it will carry call media and see '
              "both partners' IP addresses.",);
      // Scoped to the third-party table, not the whole document: the
          // failure message promises a row, so the assertion has to be about
          // one. The table runs from the Supabase row to the end of its
          // <table>.
      final tableStart = policy.indexOf('<td>Supabase</td>');
      final tableEnd = policy.indexOf('</table>', tableStart);
      expect(tableStart, greaterThan(-1),
          reason: 'the third-party table in web/privacy-policy.html has moved; '
              'this law can no longer find it',);
      final table = policy.substring(tableStart, tableEnd);
      expect(table.contains(company!), isTrue,
          reason: '$company relays calls but has no row in the third-party '
              'table of web/privacy-policy.html. A relay receives user data; '
              'the policy must say so in the same change that enables it.',);
    }
  });

  test('no storage object is served without authentication', () {
    // getPublicUrl builds a /object/public/... link, which bypasses RLS
    // entirely: no token, no expiry, no revocation. couple_media held 255 of a
    // couple's photos that way. Every bucket is private now and every read
    // signs, so a reappearance of this call is a bucket quietly going public
    // again — which is exactly how it happened the first time, one convenient
    // one-liner at a time.
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final s = lines[i].trim();
        if (s.startsWith('//') || s.startsWith('///')) continue;
        if (s.contains('getPublicUrl')) {
          offenders.add('${f.uri.pathSegments.last}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'use MediaUrls.sign / SignedImage: $offenders');
  });

  test('the app installs as itself, with every cover switched off', () {
    // This used to assert android:label="News" in the sideload manifest and
    // call that "the disguise is intact". It passed on a string sitting inside
    // .AliasNews, which ships android:enabled="false" — so it matched a name no
    // launcher has ever drawn and proved nothing about the shipped identity.
    // Both channels have installed AS MILES since 2026-08-16 (BRAIN §32/§34):
    // the covers are a feature the owner opts into from Settings, and Play's
    // Deceptive Behavior policy is satisfied precisely because no identity the
    // owner did not choose is enabled at install.
    //
    // What is asserted here is the SHIPPED DEFAULT and only that. Once
    // MainActivity has switched aliases the enabled state lives on the device,
    // not in this file — build 64 on the connected handset has .AliasMiles
    // disabled and .AliasWeather enabled, and that is the feature working.
    for (final channel in ['sideload', 'play']) {
      final xml = File('android/app/src/$channel/AndroidManifest.xml')
          .readAsStringSync();

      final app = RegExp(r'<application\b[^>]*>').firstMatch(xml)?[0];
      expect(app, isNotNull, reason: '$channel: no <application> element');
      expect(app, contains('android:label="Miles"'),
          reason: '$channel: the app installs under its own name',);

      final aliases = RegExp(r'<activity-alias\b[^>]*>')
          .allMatches(xml)
          .map((m) => m[0]!)
          .toList();
      // Without this the check passes by matching nothing — a manifest the
      // regex has stopped understanding would read as a compliant one.
      expect(aliases.length, greaterThan(1),
          reason: '$channel: found ${aliases.length} activity-alias tags',);

      // An alias with no android:enabled attribute defaults to ENABLED, so a
      // cover added without it ships a second launcher icon nobody chose.
      // Absent and "true" are the same failure and are counted as one.
      final enabled = <String>[];
      for (final tag in aliases) {
        final name = RegExp('android:name="([^"]+)"').firstMatch(tag)?[1];
        expect(name, isNotNull,
            reason: '$channel: an activity-alias with no android:name',);
        if (tag.contains('android:enabled="false"')) continue;
        enabled.add(name!);
      }
      expect(enabled, ['.AliasMiles'],
          reason: '$channel: one launcher alias ships enabled and it is the '
              'honest one; every cover is opt-in: $enabled',);
    }
  });
}
