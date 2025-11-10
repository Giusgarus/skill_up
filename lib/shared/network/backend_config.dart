import 'package:flutter/foundation.dart';

/// Provides environment-aware backend configuration.
class BackendConfig {
  const BackendConfig._();

  static const int _defaultPort = 8000;

  /// Returns the default base URL for the local backend.
  ///
  /// Android emulators cannot reach `127.0.0.1` on the host machine,
  /// so we point them to the special `10.0.2.2` alias.
  static String defaultBaseUrl({int port = _defaultPort}) {
    final host = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : '127.0.0.1';
    return 'http://$host:$port';
  }
}
