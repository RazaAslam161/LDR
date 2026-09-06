import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

/// These read the real AndroidManifest.xml, because the invariants they protect
/// are only expressible there and getting one wrong is not a cosmetic bug:
/// ship two enabled aliases and the user has two launcher icons; ship none and
/// the app has no icon at all and cannot be opened.
///
/// The disguise lives in the `sideload` source set, not `main`. Play's
/// Misrepresentation policy treats an app that presents itself as a Calculator
/// as an account strike, so the two channels are built from different manifests
/// and each needs its own guard: sideload must keep every alias, play must have
/// none. A test that read only `main` would pass while either one rotted.
void main() {
  late String manifest;
  late String mainManifest;
  late String playManifest;

  setUpAll(() {
    manifest =
        File('android/app/src/sideload/AndroidManifest.xml').readAsStringSync();
    mainManifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    playManifest =
        File('android/app/src/play/AndroidManifest.xml').readAsStringSync();
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

  test('the enabled alias is Miles — the app installs as itself', () {
    // Both channels now install under the app's own name and offer the covers
    // on first open, so the identity on the launcher is always one the owner
    // picked. A cover shipping enabled="true" would put an identity nobody
    // chose on the phone, which is the thing the picker exists to avoid.
    final block = aliasBlock(kPlainProfile.aliasId).firstMatch(manifest);
    expect(block, isNotNull,
        reason: 'no <activity-alias> for ${kPlainProfile.aliasId}',);
    expect(block!.group(0)!.contains('android:enabled="true"'), isTrue);
    for (final d in kDisguises) {
      final cover = aliasBlock(d.aliasId).firstMatch(manifest)!.group(0)!;
      expect(cover.contains('android:enabled="false"'), isTrue,
          reason: '${d.label} ships enabled; only Miles may',);
    }
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
    // Declared in main/, shared by both channels. On sideload the aliases carry
    // MAIN/LAUNCHER, so carrying it here too would show an extra, undisguised
    // icon; play adds it back in its own manifest, where there is no alias left
    // to carry it.
    final activity = RegExp(
      r'<activity\s+android:name="\.MainActivity".*?</activity>',
      dotAll: true,
    ).firstMatch(mainManifest);
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

  test('the application label is the app itself, on both channels', () {
    // Android shows THIS in Settings > Apps and it cannot be changed at
    // runtime — the aliases only rename the launcher entry. It used to be a
    // cover name so the disguise held up under inspection; it is the real name
    // now, because the app installs as itself and the cover is something the
    // owner turns on afterwards. The picker says the Settings entry stays put.
    for (final m in [manifest, playManifest]) {
      final application =
          RegExp('<application[^>]*>', dotAll: true).firstMatch(m);
      expect(application, isNotNull);
      expect(application!.group(0),
          contains('android:label="${kPlainProfile.label}"'),);
    }
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

  test('the play channel installs as itself, covers off', () {
    // The play channel ships the covers now, and what makes that publishable
    // is not their absence but their state: exactly one alias enabled, and it
    // is the honest one. An enabled cover here is a launcher identity the user
    // never chose, which is the Deceptive Behavior finding itself.
    final enabled = RegExp(
      '<activity-alias(?:(?!</activity-alias>).)*?android:enabled="true"'
      '(?:(?!</activity-alias>).)*?</activity-alias>',
      dotAll: true,
    ).allMatches(playManifest).toList();
    expect(enabled.length, 1,
        reason: '${enabled.length} enabled aliases on play; exactly one may be',);
    expect(enabled.single.group(0)!.contains('android:name=".AliasMiles"'), isTrue,
        reason: 'the enabled play alias must be the app itself',);
    expect(enabled.single.group(0)!.contains('ic_disguise'), isFalse,
        reason: 'the honest identity cannot wear a cover icon',);

    // Every cover is declared and every one of them is off.
    for (final d in kDisguises) {
      final alias = RegExp(
        '<activity-alias(?:(?!</activity-alias>).)*?'
        'android:name="\\.Alias${d.aliasId}"'
        '(?:(?!</activity-alias>).)*?</activity-alias>',
        dotAll: true,
      ).firstMatch(playManifest);
      expect(alias, isNotNull,
          reason: '${d.label} is offered in the picker but play declares no '
              'alias for it — applying it would throw',);
      expect(alias!.group(0)!.contains('android:enabled="false"'), isTrue,
          reason: '${d.label} ships ENABLED on play — a cover nobody chose',);
    }
  });

  test('the play channel still has exactly one way in', () {
    // Exactly one launcher entry, and it belongs to the alias rather than the
    // activity: a filter on MainActivity itself would be a tenth identity that
    // the switch cannot disable, so the app could never fully leave a cover.
    final enabledLaunchers = RegExp(
      'android:enabled="true"(?:(?!</activity-alias>).)*?'
      r'android\.intent\.category\.LAUNCHER',
      dotAll: true,
    ).allMatches(playManifest).length;
    expect(enabledLaunchers, 1,
        reason: '$enabledLaunchers enabled launcher entries on play',);
    final activity = RegExp(
      r'<activity\s+android:name="\.MainActivity"[^>]*/>',
    ).firstMatch(playManifest);
    expect(activity, isNotNull,
        reason: 'play declares no self-closing MainActivity — if it carries an '
            'intent-filter, that is a launcher entry no alias can turn off',);
  });

  test('the share target follows the plain identity, on both channels', () {
    // The share sheet labels every entry with the APPLICATION name and icon
    // (Android 10+), so a filter on MainActivity read "Miles" beside the Miles
    // icon under every cover. On .AliasMiles it resolves only while the app
    // wears its own name; under a cover the app is absent from the sheet.
    const send = '<action android:name="android.intent.action.SEND" />';
    expect(mainManifest.contains(send), isFalse,
        reason: 'a share target on MainActivity is on under every cover',);
    for (final entry in {'sideload': manifest, 'play': playManifest}.entries) {
      final targets = RegExp(
        '<activity-alias.*?</activity-alias>',
        dotAll: true,
      )
          .allMatches(entry.value)
          .map((m) => m.group(0)!)
          .where((a) => a.contains(send))
          .toList();
      expect(targets.length, 1,
          reason: '${entry.key}: ${targets.length} share targets',);
      expect(targets.single, contains('android:name=".AliasMiles"'),
          reason: '${entry.key}: the share target is not the plain identity',);
      // Without DEFAULT or the mime type the filter matches no implicit SEND.
      expect(targets.single, contains('android.intent.category.DEFAULT'),
          reason: '${entry.key}: share filter has no DEFAULT category',);
      expect(targets.single, contains('android:mimeType="text/plain"'),
          reason: '${entry.key}: share filter has no text/plain type',);
    }
  });

  test('the Miles launcher icon exists and survives pre-API-26', () {
    final name = RegExp('android:icon="@mipmap/([a-z0-9_]+)"')
        .firstMatch(playManifest)
        ?.group(1);
    expect(name, isNotNull, reason: 'play declares no launcher icon');
    // Shared: both channels install as Miles now, so the icon moved out of the
    // play source set into main/ where each can reach it.
    final res = Directory('android/app/src/main/res');
    final buckets = res
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split(RegExp(r'[\\/]')).last.startsWith('mipmap'))
        .toList();
    final fallback = buckets
        .where((d) => !d.path.endsWith('mipmap-anydpi-v26'))
        .any((d) => d
            .listSync()
            .whereType<File>()
            .any((f) => f.uri.pathSegments.last.split('.').first == name),);
    expect(fallback, isTrue,
        reason: '@mipmap/$name has no pre-API-26 fallback; minSdk is below 26',);
  });
}
