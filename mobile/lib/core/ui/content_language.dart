import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which language the app's *written content* is served in.
///
/// This is deliberately not app localisation. Every label, button and screen
/// title in Miles is English and stays English — what switches here is the
/// couple-facing writing: the game prompts and the truth-or-dare cards. That
/// writing was authored in Roman Urdu for one couple, and shipping it to
/// everyone would hand an English-speaking pair a game they cannot read.
/// English is therefore the default, and Roman Urdu is a choice.
///
/// The 250-note love-note pool is the one body of writing NOT covered: it sits
/// behind `FeatureFlags.pooledLoveNotes`, which is off, and an English version
/// of it is a rewrite rather than a translation — the affection is carried by
/// Urdu pet names with no English equivalent. Wire it here when that feature
/// ships and the English pool exists.
///
/// Both pools are index-aligned, so switching re-renders whatever is already on
/// screen instead of drawing a new card — the same thought, the other language.
enum ContentLanguage {
  english('English', 'EN'),
  romanUrdu('Roman Urdu', 'UR');

  const ContentLanguage(this.label, this.short);

  /// Full name, for the settings row.
  final String label;

  /// Two letters, for the inline toggle where there is no room for more.
  final String short;

  ContentLanguage get other =>
      this == english ? ContentLanguage.romanUrdu : ContentLanguage.english;
}

/// The chosen content language, restored from disk on first read.
final contentLanguageProvider =
    StateNotifierProvider<ContentLanguageNotifier, ContentLanguage>(
  (ref) => ContentLanguageNotifier(),
);

class ContentLanguageNotifier extends StateNotifier<ContentLanguage> {
  ContentLanguageNotifier() : super(ContentLanguage.english) {
    _restore();
  }

  static const _key = 'content_language';

  Future<void> _restore() async {
    final saved = (await SharedPreferences.getInstance()).getString(_key);
    if (saved == null || !mounted) return;
    final match = ContentLanguage.values.where((l) => l.name == saved);
    if (match.isNotEmpty) state = match.first;
  }

  Future<void> set(ContentLanguage lang) async {
    if (lang == state) return;
    state = lang; // optimistic: the UI must not wait on a disk write
    await (await SharedPreferences.getInstance()).setString(_key, lang.name);
  }

  Future<void> toggle() => set(state.other);
}
