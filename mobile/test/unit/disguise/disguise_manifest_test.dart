import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

/// These read the real AndroidManifest.xml, because the invariants they protect
/// are only expressible there and getting one wrong is not a cosmetic bug:
/// ship two enabled aliases and the user has two launcher icons; ship none and
/// the app has no icon at all and cannot be opened.
void main() {
  late String manifest;

  setUpAll(() {
    manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  });

  RegExp aliasBlock(String id) => RegExp(
        '<activity-alias[^>]*android:name="\\.Alias$id".*?</activity-alias>',
        dotAll: true,
      );

  test('exactly one alias ships enabled', () {
    // Zero enabled = no launcher icon and no way back in. Two = two icons,
    // which is the opposite of a disguise. Counted across real <activity-alias>
    // declarations only — matching raw text would also catch the comment that
    // documents this very rule.
    final aliases = RegExp('<activity-alias.*?</activity-alias>', dotAll: true)
        .allMatches(manifest)
        .map((m) => m.group(0)!);
    expect(aliases, isNotEmpty, reason: 'no aliases declared at all');
    final enabled =
        aliases.where((a) => a.contains('android:enabled="true"')).toList();
    expect(enabled.length, 1,
        reason: '${enabled.length} aliases are enabled; exactly 1 must be',);
  });

  test('the enabled alias is the catalog default', () {
    final block = aliasBlock(kDefaultDisguise.aliasId).firstMatch(manifest);
    expect(block, isNotNull,
        reason: 'no <activity-alias> for ${kDefaultDisguise.aliasId}',);
    expect(block!.group(0)!.contains('android:enabled="true"'), isTrue);
  });

  test('every offered disguise has a manifest alias', () {
    for (final d in kDisguises) {
      expect(aliasBlock(d.aliasId).hasMatch(manifest), isTrue,
          reason: '${d.label} is offered but has no <activity-alias>',);
    }
  });

  test('every alias is a launcher entry pointing at MainActivity', () {
    for (final d in kDisguises) {
      final block = aliasBlock(d.aliasId).firstMatch(manifest)!.group(0)!;
      expect(block.contains('android.intent.category.LAUNCHER'), isTrue);
      expect(block.contains('android:targetActivity=".MainActivity"'), isTrue);
      // API 31+ refuses to install an exported-ambiguous component.
      expect(block.contains('android:exported="true"'), isTrue);
    }
  });

  test('MainActivity itself is not a launcher entry', () {
    // It has aliases; if it also carried MAIN/LAUNCHER the app would show an
    // extra, undisguised icon.
    final activity = RegExp(
      r'<activity\s+android:name="\.MainActivity".*?</activity>',
      dotAll: true,
    ).firstMatch(manifest);
    expect(activity, isNotNull);
    expect(activity!.group(0)!.contains('android.intent.category.LAUNCHER'),
        isFalse,);
  });

  test('every launcher icon the manifest names actually exists', () {
    // A missing icon resource is a build failure at best and an app with no
    // visible icon at worst, and neither shows up in `flutter analyze`.
    final refs = RegExp('android:icon="@(mipmap|drawable)/([a-z0-9_]+)"')
        .allMatches(manifest);
    expect(refs, isNotEmpty);
    for (final m in refs) {
      final kind = m.group(1)!;
      final name = m.group(2)!;
      final dir = Directory('android/app/src/main/res');
      final found = dir
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split(RegExp(r'[\\/]')).last.startsWith(kind))
          .any((d) => d
              .listSync()
              .whereType<File>()
              .any((f) => f.uri.pathSegments.last.split('.').first == name),);
      expect(found, isTrue, reason: '@$kind/$name is referenced but missing');
    }
  });

  test('adaptive icons have a pre-API-26 fallback', () {
    // minSdk is 23, and mipmap-anydpi-v26 is only consulted from API 26. Below
    // that Android needs the same name in a non-anydpi bucket — either a
    // density folder (how the stock ic_launcher does it, as PNGs) or the
    // density-agnostic mipmap/ (how the disguise icons do it, as vectors).
    final res = Directory('android/app/src/main/res');
    final fallbackDirs = res
        .listSync()
        .whereType<Directory>()
        .where((d) {
          final n = d.path.split(RegExp(r'[\\/]')).last;
          return n.startsWith('mipmap') && n != 'mipmap-anydpi-v26';
        })
        .toList();

    // Only icons the manifest actually references. Unused leftovers in res/
    // (ic_launcher_round, which nothing points at) are not a shipping risk.
    final referenced = RegExp('android:icon="@mipmap/([a-z0-9_]+)"')
        .allMatches(manifest)
        .map((m) => m.group(1)!)
        .toSet();

    for (final f in Directory('${res.path}/mipmap-anydpi-v26')
        .listSync()
        .whereType<File>()
        .where((f) =>
            referenced.contains(f.uri.pathSegments.last.split('.').first),)) {
      final base = f.uri.pathSegments.last.split('.').first;
      final found = fallbackDirs.any((d) => d
          .listSync()
          .whereType<File>()
          .any((c) => c.uri.pathSegments.last.split('.').first == base),);
      expect(found, isTrue,
          reason: '$base has no pre-API-26 fallback in any mipmap bucket',);
    }
  });

  test('no launcher shortcuts are declared', () {
    // The launcher long-press popup is a surface the disguise does not control:
    // a static or dynamic shortcut would list a real feature of this app under
    // whatever the icon claims to be — "New note" on a spirit level. There are
    // none, and this is the check that keeps it that way when a plugin
    // helpfully adds one.
    expect(manifest.contains('android.app.shortcuts'), isFalse,
        reason: 'a shortcut names a feature the cover cannot explain',);
    expect(File('android/app/src/main/res/xml/shortcuts.xml').existsSync(),
        isFalse,);
  });

  test('the application label is the default disguise, never the real name', () {
    // Android shows THIS in Settings > Apps, and it cannot be changed at
    // runtime — the aliases only rename the launcher entry. It must therefore
    // be a disguise, and the picker tells the user it stays put.
    final application =
        RegExp(r'<application[^>]*>', dotAll: true).firstMatch(manifest);
    expect(application, isNotNull);
    expect(application!.group(0)!,
        contains('android:label="${kDefaultDisguise.label}"'),);
  });

  test('each offered disguise declares a launcher label and icon', () {
    for (final d in kDisguises) {
      final block = aliasBlock(d.aliasId).firstMatch(manifest)!.group(0)!;
      // The label the launcher shows comes from the manifest, so it must match
      // what the picker promised the user.
      expect(block.contains('android:label="${d.label}"'), isTrue,
          reason: '${d.aliasId} label does not match the catalog',);
      expect(block.contains('android:icon="'), isTrue);
    }
  });
}
