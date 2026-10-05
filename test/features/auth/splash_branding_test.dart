import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:hisaably/core/config/app_version.dart';
import 'package:hisaably/core/constants/app_constants.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/features/auth/presentation/splash_screen.dart';

import '../../helpers/fake_auth_repository.dart';

void main() {
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'Hisaably',
      packageName: 'com.bikash.hisaably',
      version: '1.1.0',
      buildNumber: '2',
      buildSignature: '',
    ),
  );

  test('version label', () {
    expect(formatAppVersion('1.1.0'), 'v1.1');
    expect(formatAppVersion('1.1.2'), 'v1.1.2');
    expect(formatAppVersion('2.0'), 'v2.0');
  });

  testWidgets('start-up screen: logo, slogan and the Powered by credit', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const MaterialApp(home: SplashScreen()),
      ),
    );
    // The start-up spinner never settles; just let the logo build in.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(AppConstants.appName), findsOneWidget);
    expect(find.text('Saaf hisaab, pakki dosti.'), findsOneWidget);
    expect(find.text('POWERED BY'), findsOneWidget);
    expect(find.text('BIKASH'), findsOneWidget);
    expect(find.text('v1.1'), findsOneWidget);
  });
}
