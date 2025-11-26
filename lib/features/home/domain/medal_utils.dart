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

  final ratio = completed / total;

  if (ratio >= 1.0) {
    return MedalType.gold;
  }
  if (ratio >= 0.66) {
    return MedalType.silver;
  }
  if (ratio >= 0.33) {
    return MedalType.bronze;
  }

  return MedalType.none;
}

String medalCodeForType(MedalType medal) {
  switch (medal) {
    case MedalType.gold:
      return 'G';
    case MedalType.silver:
      return 'S';
    case MedalType.bronze:
      return 'B';
    case MedalType.none:
      return 'None';
  }
}

MedalType medalTypeFromCode(String? code) {
  final normalized = (code ?? '').trim().toUpperCase();
  switch (normalized) {
    case 'G':
    case 'GOLD':
      return MedalType.gold;
    case 'S':
    case 'SILVER':
      return MedalType.silver;
    case 'B':
    case 'BRONZE':
      return MedalType.bronze;
    case 'NONE':
    default:
      return MedalType.none;
  }
}
