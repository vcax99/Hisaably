import 'package:flutter/material.dart';

/// App-wide snackbar host, for messages that don't come from a screen
/// (e.g. a push notification arriving while the app is open).
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
