import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_constants.dart';
import 'core/sync/sync_bootstrap.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/root_messenger.dart';
import 'core/widgets/wave_background.dart';
import 'features/auth/application/session_controller.dart';
import 'features/notifications/application/notifications_providers.dart';
import 'routing/app_router.dart';

class HisaablyApp extends ConsumerStatefulWidget {
  const HisaablyApp({super.key});

  @override
  ConsumerState<HisaablyApp> createState() => _HisaablyAppState();
}

class _HisaablyAppState extends ConsumerState<HisaablyApp> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<void>? _syncResults;
  StreamSubscription<void>? _networkRegained;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        // Re-check account status/role so a disabled account or role change
        // takes effect quickly, and send anything queued while away.
        ref.read(sessionControllerProvider.notifier).refresh();
        unawaited(syncOnResume(ref));
        ref.invalidate(unreadNotificationsProvider);
      },
      onPause: () => syncOnPause(ref),
    );
    _syncResults = subscribeToSyncResults(ref);
    _networkRegained = subscribeToNetworkRegained(ref);
    final session = ref.read(sessionControllerProvider).value;
    if (session is SessionSignedIn) {
      unawaited(onSignedIn(ref, session.context.profile.id));
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_syncResults?.cancel());
    unawaited(_networkRegained?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    listenToSyncResults(ref);
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      builder: (context, child) =>
          WaveClockScope(child: child ?? const SizedBox.shrink()),
    );
  }
}
