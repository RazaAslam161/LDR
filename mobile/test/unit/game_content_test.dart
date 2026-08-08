import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/content_language.dart';
import 'package:miles/features/games/game_content.dart';
import 'package:miles/features/games/truth_dare_deck.dart';

/// The two phones agree on a card by its POSITION in the pool, not by its text
/// — that is what lets one partner read English while the other reads Roman
/// Urdu and both still see the same question. One extra line on either side
/// shifts every card after it, and the game silently desyncs. These pin it.
void main() {
  group('pools are index-aligned across languages', () {
    test('truth pools match in length, tier by tier', () {
      for (final tier in TDTier.values) {
        expect(
          truthPool(ContentLanguage.english, tier).length,
          truthPool(ContentLanguage.romanUrdu, tier).length,
          reason: 'truth/${tier.name} would desync',
        );
      }
    });

    test('dare pools match in length, tier by tier', () {
      for (final tier in TDTier.values) {
        expect(
          darePool(ContentLanguage.english, tier).length,
          darePool(ContentLanguage.romanUrdu, tier).length,
          reason: 'dare/${tier.name} would desync',
        );
      }
    });

    test('would-you-rather and never-have-i-ever match in length', () {
      expect(wyrPool(ContentLanguage.english).length,
          wyrPool(ContentLanguage.romanUrdu).length);
      expect(nhiePool(ContentLanguage.english).length,
          nhiePool(ContentLanguage.romanUrdu).length);
    });

    test('no pool is empty', () {
      for (final lang in ContentLanguage.values) {
        expect(wyrPool(lang), isNotEmpty);
        expect(nhiePool(lang), isNotEmpty);
        for (final tier in TDTier.values) {
          expect(truthPool(lang, tier), isNotEmpty);
          expect(darePool(lang, tier), isNotEmpty);
        }
      }
    });

    test('the two languages actually differ', () {
      // A copy-paste that left one pool in the other language would pass every
      // length check above while shipping the exact bug this feature fixes.
      expect(
        wyrPool(ContentLanguage.english).first,
        isNot(wyrPool(ContentLanguage.romanUrdu).first),
      );
      expect(
        truthPool(ContentLanguage.english, TDTier.cute).first,
        isNot(truthPool(ContentLanguage.romanUrdu, TDTier.cute).first),
      );
    });
  });

  group('localiseTD', () {
    test('renders the partner index in this phone language', () {
      final theirs = truthPool(ContentLanguage.romanUrdu, TDTier.cute);
      final mine = truthPool(ContentLanguage.english, TDTier.cute);
      const at = 7;

      final card =
          localiseTD(ContentLanguage.english, TDType.truth, TDTier.cute, at);
      expect(card?.text, mine[at]);
      expect(card?.index, at);
      expect(theirs[at], isNot(mine[at])); // the two really are different pools
    });

    test('returns null when there is no index', () {
      // An older build on the other phone sends none. The caller shows their
      // words but must not file them in our bag.
      expect(
        localiseTD(ContentLanguage.english, TDType.dare, TDTier.flirty, -1),
        isNull,
      );
    });

    test('returns null when the index is past the end of our pool', () {
      expect(
        localiseTD(ContentLanguage.english, TDType.truth, TDTier.spicy, 999999),
        isNull,
      );
    });
  });

  group('TDCard wire format', () {
    test('round-trips through json', () {
      const card = TDCard(TDType.dare, TDTier.spicy, 'do the thing', 12);
      final back = TDCard.fromJson(card.toJson());
      expect(back?.type, TDType.dare);
      expect(back?.tier, TDTier.spicy);
      expect(back?.text, 'do the thing');
      expect(back?.index, 12);
    });

    test('an old payload with no index decodes as -1', () {
      final back = TDCard.fromJson(
        {'type': 'truth', 'tier': 'cute', 'text': 'old card'},
      );
      expect(back?.index, -1);
    });
  });

  group('a card is looked up by its OWN tier', () {
    test('a tier change while a card is up does not swap the question', () {
      // Truth-or-Dare broadcasts the game's current tier and the card as two
      // separate fields, and either partner can change the heat while a card is
      // showing. Indexing into the NEW tier's pool would put a different
      // question on each phone — and flirty/spicy are the same length, so it
      // would happen every single time.
      const at = 42;

      final byOwnTier = localiseTD(
        ContentLanguage.english,
        TDType.truth,
        TDTier.flirty, // the card's tier, not whatever chip is now selected
        at,
      );
      expect(
          byOwnTier?.text, truthPool(ContentLanguage.english, TDTier.flirty)[at]);
      expect(
        byOwnTier?.text,
        isNot(truthPool(ContentLanguage.english, TDTier.spicy)[at]),
        reason: 'the two tiers must be distinguishable for this test to mean '
            'anything',
      );
    });
  });
}
