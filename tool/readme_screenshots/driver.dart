import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves the README test's screenshots to build/readme_screens/NAME.png.
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    File('build/readme_screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return true;
  },
);
