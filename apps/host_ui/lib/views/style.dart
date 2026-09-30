import 'package:flutter/material.dart';

/// 状態の色。意味を持たせるのはこの 3 つだけ
abstract final class StatusColors {
  static const request = Color(0xFFE08A00);
  static const streaming = Color(0xFF2E9E4F);
  static const error = Color(0xFFD64541);
}

/// URL とトークンは等幅で出す。読み上げて手入力する場面がある
const monospace = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Consolas', 'monospace'],
);

extension SecondaryText on BuildContext {
  Color get secondary => Theme.of(this).colorScheme.onSurfaceVariant;
}
