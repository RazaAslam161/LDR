import 'package:supabase_flutter/supabase_flutter.dart';

/// Maps raw Supabase/network auth errors to friendly, actionable messages.
///
/// Typed first, substrings only as the fallback. Matching English prose is how
/// a rate limit, an invalid address and a dead socket all came out as
/// "Something went wrong. Please try again." — and how a Postgres pooler error
/// containing the word `connection` told users to check their phone's clock.
String friendlyAuthError(Object e) {
  // Rate limits, before anything else and by code rather than by wording.
  //
  // These used to fall through to the generic ending, whose advice — try again
  // now — is the one instruction that re-extends the window. GoTrue's built-in
  // mailer is shared and its per-address reset limit is one a minute, so this
  // is an ordinary outcome for anyone tapping twice, not an edge case.
  if (e is AuthException) {
    final code = e.code;
    if (e.statusCode == '429' ||
        code == 'over_request_rate_limit' ||
        code == 'over_email_send_rate_limit') {
      return 'Too many attempts just now. Wait a minute before trying again — '
          'trying sooner only restarts the clock.';
    }
    if (code == 'validation_failed' || code == 'email_address_invalid') {
      return "That email address doesn't look right. Check it and try again.";
    }
    if (code == 'weak_password') {
      return 'That password is too easy to guess. Use at least 8 characters.';
    }
  }

  // Can't reach the server at all. Typed, so it no longer depends on the word
  // `connection` appearing in a message that may be about something else.
  if (e is AuthRetryableFetchException) {
    return "Couldn't reach the server. Check this phone's internet "
        'connection and that its date & time are set automatically, '
        'then try again.';
  }

  final s = e.toString().toLowerCase();

  if (s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('handshake') ||
      s.contains('clientexception') ||
      s.contains('timed out')) {
    return "Couldn't reach the server. Check this phone's internet "
        'connection and that its date & time are set automatically, '
        'then try again.';
  }

  if (s.contains('invalid login') ||
      s.contains('invalid_credentials') ||
      s.contains('invalid credentials')) {
    return 'Email or password is incorrect.';
  }
  if (s.contains('email not confirmed') || s.contains('not confirmed')) {
    return 'Please confirm your email first, then sign in.';
  }
  if (s.contains('user already registered') ||
      s.contains('already registered')) {
    return 'An account with this email already exists. Try signing in.';
  }
  // Eight, matching what both password fields ask for and what
  // NewPasswordPage enforces. It said six for as long as the screens said
  // eight, so the one message a user saw after being refused told them to do
  // something that would be refused again.
  if (s.contains('password') && s.contains('at least')) {
    return 'Password must be at least 8 characters.';
  }

  return 'Something went wrong. Please try again.';
}
