import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host-side driver for `flutter drive`: saves screenshots taken by the
/// integration test to `build/device_screenshots/NAME.png`.
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    final file = File('build/device_screenshots/$name.png')
      ..createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return true;
  },
);
