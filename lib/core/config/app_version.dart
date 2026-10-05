import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// "v1.1" from the installed app's version (pubspec `version:`); a trailing
/// ".0" patch is dropped. Null if it can't be read.
final appVersionProvider = FutureProvider<String?>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return formatAppVersion(info.version);
  } catch (_) {
    return null;
  }
});

String formatAppVersion(String version) {
  final parts = version.split('.');
  if (parts.length == 3 && parts[2] == '0') parts.removeLast();
  return 'v${parts.join('.')}';
}
