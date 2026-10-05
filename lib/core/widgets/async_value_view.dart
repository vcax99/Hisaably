import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/app_failure.dart';
import '../errors/error_mapper.dart';
import 'empty_state.dart';

/// Standard loading / error (with retry) / data rendering for an AsyncValue.
/// Keeps showing previous data while refreshing.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    required this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (value.hasValue) return data(value.requireValue);
    if (value.hasError) {
      final AppFailure failure = mapError(value.error!, value.stackTrace);
      return EmptyState(
        icon: failure is NetworkFailure
            ? Icons.cloud_off_rounded
            : Icons.error_outline_rounded,
        title: failure is NetworkFailure ? 'You are offline' : 'Could not load',
        message: failure.message,
        actionLabel: 'Try again',
        onAction: onRetry,
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}
