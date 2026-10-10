/// Spec 7.2: every sync call must be sure which relay it is talking to, so
/// this phone never signs a record or hands over its bearer token to the
/// wrong server. A release build must always use `https`. A debug build may
/// use plain `http`, but only to reach a relay on this developer's own
/// machine — the Android emulator's alias for the host is `10.0.2.2`.
class RelayUrlError implements Exception {
  const RelayUrlError(this.message);

  final String message;

  @override
  String toString() => message;
}

const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

/// Checks [raw] (normally `--dart-define=RELAY_URL=...`) and returns the
/// parsed [Uri], or throws [RelayUrlError] with a message fit to show the
/// developer. [debug] is a parameter, not read from `kDebugMode` here, so
/// this function stays pure and both branches can be driven directly from
/// a test.
Uri validateRelayUrl(String raw, {required bool debug}) {
  if (raw.trim().isEmpty) {
    throw const RelayUrlError(
      'No relay address was set. Build with --dart-define=RELAY_URL=... .',
    );
  }

  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw RelayUrlError('"$raw" is not a valid web address.');
  }

  if (uri.scheme == 'https') return uri;

  if (uri.scheme != 'http') {
    throw RelayUrlError(
      'The relay address must start with https://, not "${uri.scheme}://".',
    );
  }
  if (!debug) {
    throw const RelayUrlError(
      'The relay address must start with https:// in a release build.',
    );
  }
  if (!_localHosts.contains(uri.host)) {
    throw RelayUrlError(
      'Plain http:// is only allowed for a local relay (localhost, '
      '127.0.0.1 or 10.0.2.2), not "${uri.host}".',
    );
  }
  return uri;
}
