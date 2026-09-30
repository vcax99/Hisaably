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
}
