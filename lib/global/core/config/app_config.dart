/// Centralized configuration for environment-specific values.
/// Change these per environment (dev/staging/prod).
class AppConfig {
  AppConfig._();

  /// Base URL for the API (no trailing slash)
  static const String baseUrl = 'http://108.181.195.154:3000/api/v1';

  /// Google Sign-In client ID
  static const String googleClientId =
      '914828544219-v3sbd8bcui352873r4teffmcme2dtmqs.apps.googleusercontent.com';

  /// Request timeout duration
  static const Duration requestTimeout = Duration(seconds: 100);
}
