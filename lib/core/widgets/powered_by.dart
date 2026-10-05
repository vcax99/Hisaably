import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_version.dart';

import '../constants/app_constants.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// "POWERED BY / BIKASH" credit for the start-up screen, in Orbitron so it
/// stands apart from the app's own typography.
class PoweredBy extends ConsumerWidget {
  const PoweredBy({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).value;
    return Column(
      key: const Key('powered-by'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'POWERED BY',
          style: TextStyle(
            fontFamily: AppFonts.brand,
            fontSize: 11,
            letterSpacing: 3,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          AppConstants.author.toUpperCase(),
          style: const TextStyle(
            fontFamily: AppFonts.brand,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            letterSpacing: 6,
            color: AppColors.accent,
          ),
        ),
        if (version != null) ...[
          const SizedBox(height: 10),
          Text(
            version,
            key: const Key('app-version'),
            style: const TextStyle(
              fontFamily: AppFonts.brand,
              fontSize: 11,
              letterSpacing: 2,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}
