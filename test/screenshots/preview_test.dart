// Renders the REAL app screens to PNG files (no device needed), using a fake
// backend. Skipped in normal test runs. Generate with:
//   scripts/render_screens.sh      -> build/screenshots/*.png
@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/app.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/features/auth/data/auth_repository.dart';
import 'package:hisaably/routing/app_router.dart';
import 'package:hisaably/routing/routes.dart';

import '../helpers/fake_auth_repository.dart';

final _flutterRoot = Platform.environment['FLUTTER_ROOT'];
final _skip =
    _flutterRoot == null || Platform.environment['RENDER_SCREENS'] != '1'
    ? 'Run scripts/render_screens.sh to generate screenshots'
    : null;
const _outDir = 'build/screenshots';
const _boundary = ValueKey('screenshot-boundary');

Future<void> _loadFonts() async {
  final dir = '$_flutterRoot/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String f) async =>
      ByteData.sublistView(File('$dir/$f').readAsBytesSync());

  final roboto = FontLoader('Roboto');
  for (final f in [
    'Roboto-Light.ttf',
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    roboto.addFont(read(f));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(read('MaterialIcons-Regular.otf'))).load();
}

Future<GoRouterHolder> _pump(
  WidgetTester tester,
  FakeAuthRepository repo,
) async {
  // iPhone 14/15-sized logical screen (390 x 844 @3x).
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repo)],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: UncontrolledProviderScope(
        container: container,
        child: const HisaablyApp(),
      ),
    ),
  );
  return GoRouterHolder(container);
}

class GoRouterHolder {
  GoRouterHolder(this.container);
  final ProviderContainer container;
  void go(String path) => container.read(appRouterProvider).go(path);
}

Future<void> _shot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_outDir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

FakeAuthRepository _repo({String? signedInAs}) => FakeAuthRepository(
  accounts: {
    'asha': FakeAccount('secret123', memberContext),
    'vcax99': FakeAccount('admin-pass', superAdminContext),
  },
  signedInAs: signedInAs,
);

Future<void> _type(WidgetTester tester, String label, String text) =>
    tester.enterText(find.widgetWithText(TextFormField, label), text);

void main() {
  setUpAll(() async {
    if (_skip == null) await _loadFonts();
  });

  testWidgets('01 splash loading', (tester) async {
    final gate = Completer<void>();
    final repo = _repo(signedInAs: 'asha')..fetchGate = gate.future;
    await _pump(tester, repo);
    await tester.pump(const Duration(milliseconds: 400));
    await _shot(tester, '01_splash_loading');
    gate.complete();
    await tester.pumpAndSettle();
  }, skip: _skip != null);

  testWidgets('02 splash offline error', (tester) async {
    final repo = _repo(signedInAs: 'asha')..fetchError = const NetworkFailure();
    await _pump(tester, repo);
    await tester.pumpAndSettle();
    await _shot(tester, '02_splash_offline');
  }, skip: _skip != null);

  testWidgets('03-04 login', (tester) async {
    await _pump(tester, _repo());
    await tester.pumpAndSettle();
    await _shot(tester, '03_login');

    await _type(tester, 'Username', 'asha');
    await _type(tester, 'Password', 'wrong-password');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _shot(tester, '04_login_error');
  }, skip: _skip != null);

  testWidgets('05-07 member', (tester) async {
    final app = await _pump(tester, _repo(signedInAs: 'asha'));
    await tester.pumpAndSettle();
    await _shot(tester, '05_member_dashboard');

    await tester.tap(find.bySemanticsLabel('Add transaction'));
    await tester.pumpAndSettle();
    await _shot(tester, '06_member_add_sheet');
    await tester.tapAt(const Offset(195, 120));
    await tester.pumpAndSettle();

    app.go(Routes.memberExpenses);
    await tester.pumpAndSettle();
    await _shot(tester, '07_member_expenses');
  }, skip: _skip != null);

  testWidgets('08-10 super admin', (tester) async {
    final app = await _pump(tester, _repo(signedInAs: 'vcax99'));
    await tester.pumpAndSettle();
    await _shot(tester, '08_admin_dashboard');

    app.go(Routes.adminMore);
    await tester.pumpAndSettle();
    await _shot(tester, '09_admin_more');

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await _shot(tester, '10_account');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    await _shot(tester, '11_sign_out_dialog');
  }, skip: _skip != null);
}
