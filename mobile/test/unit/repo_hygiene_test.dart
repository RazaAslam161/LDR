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
        reason: 'git ls-files returned almost nothing; these checks are blind');
    final loose = all.where((f) => !f.contains('/')).toSet()..removeAll(allowed);
    expect(loose, isEmpty,
        reason: 'put it in mobile/, supabase/, scripts/ or docs/: $loose');
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
        reason: 'this repository ships a Flutter app: $present');
  });

  test('.env.example documents every key the app actually reads', () {
    // The one form of documentation rot that stops a new machine from
    // building at all, and it is silent: config.dart throws a StateError
    // before the first frame when a key is missing, naming the constant rather
    // than what to put in it.
    final config = File('lib/core/config.dart').readAsStringSync();
    final example = File('.env.example').readAsStringSync();
    final keys = RegExp(r"static const \w*Key\w* = '([A-Z0-9_]+)'")
        .allMatches(config)
        .map((m) => m[1]!)
        .toSet();

    expect(keys, isNotEmpty, reason: 'no env keys parsed out of config.dart');
    final undocumented = keys.where((k) => !example.contains(k)).toList();
    expect(undocumented, isEmpty,
        reason: 'read by config.dart, absent from .env.example: $undocumented');
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
            '${atDocsRoot.toSet().difference(allowedAtDocsRoot)}');
    expect(Directory('../docs/archive').existsSync(), isTrue);
  });

  test('the launcher disguise is intact', () {
    // Not cleanup-adjacent, deliberately. The label looks like a placeholder
    // somebody forgot to change, which is exactly why a well-meaning tidy-up
    // would "fix" it and quietly undo the app's whole threat model.
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:label="News"'),
        reason: 'the launcher name is a disguise and is intentional');
    expect(root.existsSync(), isTrue);
  });
}
