/// Build-time switches for features that are finished but deliberately not
/// shipped yet. Flip one to `true` and rebuild to bring the feature back.
class FeatureFlags {
  FeatureFlags._();

  /// Pooled "Send a note" in the cycle screen.
  ///
  /// Held back from the public launch. The 250-note pool is written in one
  /// couple's private Roman Urdu/Punjabi voice — the recipient's name is
  /// tokenised, but the pet names ("begum", "chuii", "churail", "bandri") are
  /// still hardcoded, the notes are gendered husband → wife, and there is no
  /// localisation. Putting those words in a stranger's mouth is a product risk,
  /// so the entry point stays hidden until the pool is tokenised per user and
  /// translated. The code and its tests are kept intact for that work.
  static const bool pooledLoveNotes = false;
}
