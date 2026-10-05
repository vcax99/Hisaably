abstract final class AppConstants {
  static const appName = 'Hisaably';
  static const author = 'Bikash';

  /// Slogan under the logo (start-up and sign-in screens).
  static const tagline = 'Saaf hisaab, pakki dosti.';

  /// Maximum ACTIVE members per group. The server enforces this; the client
  /// copy is only for UX (disabling buttons, showing counts).
  static const maxActiveMembersPerGroup = 10;

  /// Default page size for paginated transaction lists.
  static const transactionPageSize = 30;

  /// All month boundaries and "today" are evaluated in India Standard Time.
  static const businessTimeZone = 'Asia/Kolkata';
}
