import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/content_language.dart';
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
          wyrPool(ContentLanguage.romanUrdu).length,);
      expect(nhiePool(ContentLanguage.english).length,
          nhiePool(ContentLanguage.romanUrdu).length,);
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
        localiseTD(ContentLanguage.english, TDType.truth, TDTier.flirty, 999999),
        isNull,
      );
    });
  });

  group('TDCard wire format', () {
    test('round-trips through json', () {
      const card = TDCard(TDType.dare, TDTier.flirty, 'do the thing', 12);
      final back = TDCard.fromJson(card.toJson());
      expect(back?.type, TDType.dare);
      expect(back?.tier, TDTier.flirty);
      expect(back?.text, 'do the thing');
      expect(back?.index, 12);
    });

    test('an old payload with no index decodes as -1', () {
      final back = TDCard.fromJson(
        {'type': 'truth', 'tier': 'cute', 'text': 'old card'},
      );
      expect(back?.index, -1);
    });

    test('a card from a phone still on the spicy tier decodes', () {
      // The third tier was once deleted rather than reworded. fromJson returns
      // null for a tier it does not know, and truth_dare_screen does
      // `_card = ours ?? card` — so a partner on an older build drawing that
      // tier left this phone showing NO CARD, silently. The wire name outlives
      // the wording: this app is sideloaded and cannot make anyone update.
      final back = TDCard.fromJson(
        {'type': 'truth', 'tier': 'spicy', 'text': 'their words', 'index': 3},
      );
      expect(back, isNotNull);
      expect(back?.tier, TDTier.spicy);
      expect(back?.index, 3);
    });

    test('every tier that can arrive on the wire has cards in both languages',
        () {
      // A tier decoding fine but having an empty pool is the same blank screen
      // by another route: localiseTD would have nothing to look the index up in.
      for (final tier in TDTier.values) {
        for (final lang in ContentLanguage.values) {
          expect(truthPool(lang, tier), isNotEmpty, reason: '$tier $lang truth');
          expect(darePool(lang, tier), isNotEmpty, reason: '$tier $lang dare');
        }
      }
    });
  });

  group('an unknown tier on the wire', () {
    // This used to assert the opposite: that a `spicy` card decoded to null,
    // "the card simply does not appear". That WAS the bug — a partner on an
    // older build drew a card and this phone showed nothing, with no error and
    // no log. The tier is back under its original wire name, so the positive
    // case now lives in 'TDCard wire format'. What must still hold is that a
    // genuinely unknown tier degrades quietly instead of throwing.
    test('a tier this build has never heard of decodes as null', () {
      expect(
        TDCard.fromJson(
          {'type': 'dare', 'tier': 'molten', 'text': 'from a future build', 'index': 3},
        ),
        isNull,
      );
    });
  });

  group('a card is looked up by its OWN tier', () {
    test('a tier change while a card is up does not swap the question', () {
      // Truth-or-Dare broadcasts the game's current tier and the card as two
      // separate fields, and either partner can change the heat while a card is
      // showing. Indexing into the NEW tier's pool would put a different
      // question on each phone.
      const at = 42;

      final byOwnTier = localiseTD(
        ContentLanguage.english,
        TDType.truth,
        TDTier.flirty, // the card's tier, not whatever chip is now selected
        at,
      );
      expect(
          byOwnTier?.text, truthPool(ContentLanguage.english, TDTier.flirty)[at],);
      expect(
        byOwnTier?.text,
        isNot(truthPool(ContentLanguage.english, TDTier.cute)[at]),
        reason: 'the two tiers must be distinguishable for this test to mean '
            'anything',
      );
    });
  });
}
