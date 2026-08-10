/// Maps raw Supabase/network auth errors to friendly, actionable messages.
String friendlyAuthError(Object e) {
  final s = e.toString().toLowerCase();

  // Network / can't reach the server (AuthRetryableFetchException, SocketException…)
  if (s.contains('retryable') ||
      s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('handshake') ||
      s.contains('clientexception') ||
      s.contains('timed out') ||
      s.contains('connection')) {
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
  if (s.contains('password') && s.contains('at least')) {
    return 'Password must be at least 6 characters.';
  }

  return 'Something went wrong. Please try again.';
}
