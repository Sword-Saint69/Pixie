/// Turns the bridge's raw `AnyhowException` strings into short, actionable
/// messages. One place so the Upload, Accounts and Settings pages stay consistent.
String friendlyError(Object error) {
  final text = error
      .toString()
      .replaceFirst('AnyhowException(', '')
      .replaceAll(RegExp(r'\)$'), '');

  if (text.contains('Read-only file system') ||
      text.contains('replace config file')) {
    return 'Cannot write settings. Check the app storage location.';
  }
  if (text.contains('BadAuthentication') ||
      text.contains('oauth_token') ||
      text.toLowerCase().contains('auth response')) {
    return 'Google rejected this credential. Add a fresh one in Accounts.';
  }
  if (text.contains('token binding')) {
    return 'This account needs token binding, which is not supported yet.';
  }
  if (text.contains('dns error') ||
      text.contains('failed to lookup address') ||
      text.toLowerCase().contains('network') ||
      text.contains('error sending request')) {
    return 'Network unavailable — check your connection and try again.';
  }
  if (text.contains('invalid peer certificate') ||
      text.contains('UnknownIssuer')) {
    return 'Could not verify Google’s certificate. Check your device date and network.';
  }
  if (text.contains('already running')) {
    return 'An upload is already in progress.';
  }
  return text;
}
