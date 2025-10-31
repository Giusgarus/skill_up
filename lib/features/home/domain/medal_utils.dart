import 'package:flutter/material.dart';

enum MedalType { none, bronze, silver, gold }

DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String medalAssetForType(MedalType type) {
  switch (type) {
    case MedalType.gold:
      return 'assets/icons/gold_star_icon.svg';
    case MedalType.silver:
      return 'assets/icons/silver_star_icon.svg';
    case MedalType.bronze:
      return 'assets/icons/bronze_star_icon.svg';
    case MedalType.none:
      return 'assets/icons/blank_star_icon.svg';
  }
}

Color? medalTintForType(MedalType type) {
  switch (type) {
    case MedalType.none:
      return Colors.black.withValues(alpha: 0.35);
    default:
      return null;
  }
}

MedalType medalForProgress({required int completed, required int total}) {
  if (total <= 0 || completed <= 0) {
    return MedalType.none;
  }

  if (completed >= total) {
    return MedalType.gold;
  }

  final ratio = completed / total;
  if (ratio >= 0.5) {
    return MedalType.silver;
  }

  return MedalType.bronze;
}
