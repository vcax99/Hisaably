import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../application/session_controller.dart';

/// Shown while the session is being resolved, or when it couldn't be resolved
/// (e.g. first start while offline) with a retry.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final textTheme = Theme.of(context).textTheme;
    final error = session.hasError && !session.isLoading ? session.error : null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(AppConstants.appName, style: textTheme.displaySmall),
                const SizedBox(height: AppSpacing.xl),
                if (error == null)
                  const SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else ...[
                  const Icon(
                    Icons.cloud_off_rounded,
                    color: AppColors.textMuted,
                    size: 36,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    error is AppFailure
                        ? error.message
                        : const UnexpectedFailure().message,
                    style: textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton(
                    onPressed: () => ref.invalidate(sessionControllerProvider),
                    child: const Text('Try again'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: () =>
                        ref.read(sessionControllerProvider.notifier).signOut(),
                    child: const Text('Sign out'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
