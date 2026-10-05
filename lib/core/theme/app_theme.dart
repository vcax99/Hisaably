import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';

/// Bundled font families (see pubspec.yaml).
abstract final class AppFonts {
  static const display = 'Sora';
  static const body = 'Manrope';
}

abstract final class AppTheme {
  static ThemeData dark() {
    const colorScheme = ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: AppColors.onAccent,
      secondary: AppColors.accent,
      onSecondary: AppColors.onAccent,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      surfaceContainerHighest: AppColors.elevated,
      onSurfaceVariant: AppColors.textSecondary,
      outline: AppColors.border,
      outlineVariant: AppColors.border,
      error: AppColors.expense,
      onError: AppColors.textPrimary,
    );

    // Material 2021 metrics with our fonts, sizes and colours on top: Sora
    // for display/headline/title text (and big amounts), Manrope for body
    // and labels. Every other style below derives from this.
    const overrides = TextTheme(
      displaySmall: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: AppColors.textPrimary,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: AppColors.textPrimary),
      bodyMedium: TextStyle(fontSize: 14, color: AppColors.textSecondary),
      bodySmall: TextStyle(fontSize: 12, color: AppColors.textMuted),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(fontSize: 11, color: AppColors.textMuted),
    );
    final base = Typography.material2021().white
        .merge(overrides)
        .apply(fontFamily: AppFonts.body);
    TextStyle? display(TextStyle? t) =>
        t?.copyWith(fontFamily: AppFonts.display);
    final textTheme = base.copyWith(
      displayLarge: display(base.displayLarge),
      displayMedium: display(base.displayMedium),
      displaySmall: display(base.displaySmall),
      headlineLarge: display(base.headlineLarge),
      headlineMedium: display(base.headlineMedium),
      headlineSmall: display(base.headlineSmall),
      titleLarge: display(base.titleLarge),
      titleMedium: display(base.titleMedium),
    );
    final buttonText = textTheme.labelLarge!.copyWith(fontSize: 16);

    final roundedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      borderSide: const BorderSide(color: AppColors.border),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      // Every page paints its own backdrop (near-black + waves), see
      // _page in routing/app_router.dart; scaffolds stay see-through.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: AppColors.background,
      textTheme: textTheme,
      fontFamily: AppFonts.body,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge!.copyWith(fontSize: 20),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.textMuted),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: roundedBorder,
        enabledBorder: roundedBorder,
        focusedBorder: roundedBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.accent),
        ),
        errorBorder: roundedBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.expense),
        ),
        focusedErrorBorder: roundedBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.expense),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.onAccent,
          disabledBackgroundColor: AppColors.elevated,
          disabledForegroundColor: AppColors.textMuted,
          minimumSize: const Size.fromHeight(AppSpacing.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          minimumSize: const Size.fromHeight(AppSpacing.minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          minimumSize: const Size(
            AppSpacing.minTouchTarget,
            AppSpacing.minTouchTarget,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size(
            AppSpacing.minTouchTarget,
            AppSpacing.minTouchTarget,
          ),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        modalBackgroundColor: AppColors.surface,
        showDragHandle: true,
        dragHandleColor: AppColors.border,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpacing.radiusLg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.elevated,
        contentTextStyle: textTheme.bodyMedium!.copyWith(
          color: AppColors.textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        // Default action color is dark-on-dark here.
        actionTextColor: AppColors.accent,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
      ),
    );
  }
}
