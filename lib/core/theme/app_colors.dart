import 'package:flutter/material.dart';

/// Centralized color tokens. Do not use `Color(0x...)` literals anywhere else
/// in the codebase — reference these tokens (or the ThemeData built from them).
abstract final class AppColors {
  static const background = Color(0xFF0B0B0D);
  static const surface = Color(0xFF151518);
  static const elevated = Color(0xFF1D1D21);

  static const textPrimary = Color(0xFFF5F5F5);
  static const textSecondary = Color(0xFFA7A7AD);
  static const textMuted = Color(0xFF77777F);

  static const border = Color(0xFF2A2A2F);

  static const accent = Color(0xFF7CFF6B);
  static const onAccent = Color(0xFF0B0B0D);

  static const income = Color(0xFF39D98A);
  static const expense = Color(0xFFFF5C5C);
  static const warning = Color(0xFFF5B942);

  // --- Chart colours (validated with the dataviz palette validator against
  // the dark card surface #151518: lightness band, chroma, CVD ΔE ≥ 8 for
  // adjacent pairs incl. the donut's wrap-around, normal-vision ΔE ≥ 15,
  // ≥ 3:1 contrast). Fills only — chart text uses the text tokens above.

  /// Categorical order for category breakdowns. Fixed order, never cycled;
  /// anything beyond these folds into "Other" ([chartOther]).
  static const chartCategorical = <Color>[
    Color(0xFF3987E5), // blue
    Color(0xFFD95926), // orange
    Color(0xFF199E70), // aqua
    Color(0xFFC98500), // yellow
    Color(0xFFD55181), // magenta
  ];
  static const chartOther = Color(0xFF5F5F67);

  /// Income vs expense series (CVD-safe pair; brand hues stepped for fills).
  static const chartIncome = Color(0xFF1AA7A0);
  static const chartExpense = Color(0xFFDE5050);

  /// Single-series balance line (neutral — not the income green).
  static const chartBalance = Color(0xFF3987E5);

  /// Recessive grid lines.
  static const chartGrid = Color(0xFF26262B);
}
