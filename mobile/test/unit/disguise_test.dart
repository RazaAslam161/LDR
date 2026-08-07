import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

void main() {
  group('disguise catalog', () {
    test('every offered disguise has a cover that exists', () {
      // A launcher icon whose cover does not match is a louder tell than no
      // disguise at all, so the catalog may only offer covers that are built.
      const built = {DisguiseCover.news, DisguiseCover.calculator};
      for (final d in kDisguises) {
        expect(built.contains(d.cover), isTrue,
            reason: '${d.label} is offered but ${d.cover} has no cover screen');
      }
    });

    test('alias ids are unique — they map 1:1 to manifest aliases', () {
      final ids = kDisguises.map((d) => d.aliasId).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('alias ids are safe to interpolate into a component name', () {
      // MainActivity builds "$packageName.Alias$aliasId"; anything but a bare
      // identifier would silently target a component that does not exist.
      for (final d in kDisguises) {
        expect(RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(d.aliasId), isTrue,
            reason: '${d.aliasId} is not a valid component-name suffix');
      }
    });

    test('the default is the alias the manifest ships enabled', () {
      // Exactly one <activity-alias> has android:enabled="true" (News). If the
      // default here disagreed, a fresh install would render the wrong cover.
      expect(kDefaultDisguise.aliasId, 'News');
      expect(kDisguises.first.aliasId, kDefaultDisguise.aliasId);
    });

    test('an unknown or missing alias falls back to the default', () {
      expect(disguiseForAlias(null).aliasId, kDefaultDisguise.aliasId);
      expect(disguiseForAlias('Nonexistent').aliasId, kDefaultDisguise.aliasId);
      expect(disguiseForAlias('Calculator').cover, DisguiseCover.calculator);
    });
  });
}
