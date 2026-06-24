/// A normalised error for the repository layer.
///
/// Wrap `PostgrestException` / `FormatException` / unknown errors in this so the
/// provider + UI layers can show a friendly message without leaking raw
/// exception text (which can include SQL, tokens, or internals).
class RepositoryException implements Exception {
  RepositoryException(this.message, [this.cause]);

  /// A short, user-facing message — safe to show in the UI.
  final String message;

  /// The original error, kept for logging/debugging (never shown to users).
  final Object? cause;

  @override
  String toString() => 'RepositoryException: $message';
}
