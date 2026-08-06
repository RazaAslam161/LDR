import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/cycle/love_notes_pool.dart';

void main() {
  group('renderLoveNote', () {
    test('fills every {name} placeholder', () {
      expect(
        renderLoveNote('{name}, aap {name} hi ho', 'Aisha'),
        'Aisha, aap Aisha hi ho',
      );
    });

    test('trims the name so a stray space never lands mid-sentence', () {
      expect(renderLoveNote('hi {name},', '  Aisha '), 'hi Aisha,');
    });

    test('leaves a note without a placeholder untouched', () {
      expect(renderLoveNote('aap bohot pyaari ho', 'Aisha'),
          'aap bohot pyaari ho');
    });
  });

  group('kLoveNotes', () {
    // The pool ships to every user, so no real person may be named in it —
    // every form of address has to go through kLoveNoteNameToken.
    test('names no real person', () {
      const banned = ['Zunaira', 'Raza', 'Mrs', 'Mr '];
      for (final term in banned) {
        final offenders = kLoveNotes.where((n) => n.contains(term)).toList();
        expect(offenders, isEmpty,
            reason: '"$term" is hardcoded in ${offenders.length} note(s); '
                'address the user through $kLoveNoteNameToken instead');
      }
    });

    test('the notes that address her do so through the placeholder', () {
      final withToken =
          kLoveNotes.where((n) => n.contains(kLoveNoteNameToken)).length;
      expect(withToken, 155);
    });

    test('every note renders with no {name} residue', () {
      for (final note in kLoveNotes) {
        expect(renderLoveNote(note, 'Aisha'), isNot(contains('{name}')),
            reason: 'placeholder survived rendering in: $note');
      }
    });

    test('the pool is intact and non-empty', () {
      expect(kLoveNotes, hasLength(250));
      expect(kLoveNotes.every((n) => n.trim().isNotEmpty), isTrue);
    });
  });
}
