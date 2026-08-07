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
    final aliases = RegExp(r'<activity-alias.*?</activity-alias>', dotAll: true)
        .allMatches(manifest)
        .map((m) => m.group(0)!);
    expect(aliases, isNotEmpty, reason: 'no aliases declared at all');
    final enabled =
        aliases.where((a) => a.contains('android:enabled="true"')).toList();
    expect(enabled.length, 1,
        reason: '${enabled.length} aliases are enabled; exactly 1 must be');
  });

  test('the enabled alias is the catalog default', () {
    final block = aliasBlock(kDefaultDisguise.aliasId).firstMatch(manifest);
    expect(block, isNotNull,
        reason: 'no <activity-alias> for ${kDefaultDisguise.aliasId}');
    expect(block!.group(0)!.contains('android:enabled="true"'), isTrue);
  });

  test('every offered disguise has a manifest alias', () {
    for (final d in kDisguises) {
      expect(aliasBlock(d.aliasId).hasMatch(manifest), isTrue,
          reason: '${d.label} is offered but has no <activity-alias>');
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
        isFalse);
  });

  test('each offered disguise declares a launcher label and icon', () {
    for (final d in kDisguises) {
      final block = aliasBlock(d.aliasId).firstMatch(manifest)!.group(0)!;
      // The label the launcher shows comes from the manifest, so it must match
      // what the picker promised the user.
      expect(block.contains('android:label="${d.label}"'), isTrue,
          reason: '${d.aliasId} label does not match the catalog');
      expect(block.contains('android:icon="'), isTrue);
    }
  });
}
