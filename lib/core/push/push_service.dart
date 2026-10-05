import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../network/supabase_providers.dart';

/// Push delivery for Android (FCM). iOS has no push: the app is installed
/// with a free Apple team, which can't use APNs (owner decision 14); iOS
/// users see notifications in the app (bell + list).
///
/// The server decides who is notified (after commit, never the actor) and
/// sends via the send-push Edge Function; this class only keeps the device
/// token registered for the signed-in user.
class PushService {
  PushService(this._client);

  final SupabaseClient _client;
  String? _token;
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  /// A tap can arrive both as "opened" and as the initial message (and
  /// registration re-runs on every sign-in event): handle each message once.
  final _handled = <String>{};

  static bool get supported =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      Env.isConfigured &&
      Env.hasFirebase;

  /// Once at startup (before runApp).
  static Future<void> initFirebase() async {
    if (!supported) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: Env.firebaseAndroidApiKey,
          appId: Env.firebaseAndroidAppId,
          messagingSenderId: Env.firebaseSenderId,
          projectId: Env.firebaseProjectId,
        ),
      );
    } catch (e) {
      debugPrint('Firebase init failed: ${e.runtimeType}');
    }
  }

  /// After sign-in / app start while signed in: ask permission (Android 13+),
  /// register this device's token, and keep it registered on refresh.
  Future<void> register({
    required void Function(RemoteMessage message) onForeground,
    required void Function(RemoteMessage message) onOpened,
  }) async {
    if (!supported || Firebase.apps.isEmpty) return;
    void openedOnce(RemoteMessage m) {
      final id = m.messageId ?? m.data['notification_id'] as String?;
      if (id != null && !_handled.add(id)) return;
      onOpened(m);
    }

    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      _refreshSub ??= messaging.onTokenRefresh.listen(
        (t) => unawaited(_save(t)),
      );
      _messageSub ??= FirebaseMessaging.onMessage.listen(onForeground);
      _openedSub ??= FirebaseMessaging.onMessageOpenedApp.listen(openedOnce);

      final token = await messaging.getToken();
      if (token != null) await _save(token);

      final initial = await messaging.getInitialMessage();
      if (initial != null) openedOnce(initial);
    } catch (e) {
      // Offline or Play services missing: retried on the next app start.
      debugPrint('Push registration skipped: ${e.runtimeType}');
    }
  }

  Future<void> _save(String token) async {
    _token = token;
    await _client.rpc<void>(
      'register_device',
      params: {'p_token': token, 'p_platform': 'ANDROID'},
    );
  }

  /// Before signing out (while still authenticated): this device stops
  /// receiving the user's notifications.
  Future<void> unregister() async {
    if (!supported || Firebase.apps.isEmpty) return;
    try {
      final token = _token ?? await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _client.rpc<void>(
          'unregister_device',
          params: {'p_token': token},
        );
      }
    } catch (e) {
      debugPrint('Push unregister skipped: ${e.runtimeType}');
    }
  }

  void dispose() {
    unawaited(_refreshSub?.cancel());
    unawaited(_messageSub?.cancel());
    unawaited(_openedSub?.cancel());
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref.watch(supabaseClientProvider));
  ref.onDispose(service.dispose);
  return service;
});
