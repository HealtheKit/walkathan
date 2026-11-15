/// Environment-specific values. Every PLACEHOLDER must be replaced before
/// release.
abstract final class AppConfig {
  /// PLACEHOLDER: replace with the real support mailbox.
  static const String supportEmail = 'support@example.com';

  /// Maximum walker profiles per login (also enforced by the database).
  static const int maxProfilesPerAccount = 6;

  /// Bump to force the consent screen to show again.
  static const String consentKey = 'consent_v1';
}
