import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/application/session_controller.dart';
import 'routing/app_router.dart';

class HisaablyApp extends ConsumerStatefulWidget {
  const HisaablyApp({super.key});

  @override
  ConsumerState<HisaablyApp> createState() => _HisaablyAppState();
}

class _HisaablyAppState extends ConsumerState<HisaablyApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Re-check account status/role when the app returns to the foreground,
    // so a disabled account or role change takes effect quickly.
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(sessionControllerProvider.notifier).refresh(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
