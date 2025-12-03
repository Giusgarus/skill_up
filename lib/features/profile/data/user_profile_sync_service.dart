import 'dart:convert';

import '../../home/data/medal_history_repository.dart';
import '../../home/data/user_stats_repository.dart';
import '../../home/domain/medal_utils.dart';
import '../domain/user_profile_fields.dart';
import 'profile_api.dart';
import 'profile_field_mapping.dart';
import 'user_profile_info_storage.dart';
import 'user_profile_storage.dart';

const Map<MedalType, int> _medalPriority = <MedalType, int>{
  MedalType.none: 0,
  MedalType.bronze: 1,
  MedalType.silver: 2,
  MedalType.gold: 3,
};

/// Parses the backend medals payload into a normalized date/medal map.
Map<DateTime, MedalType> parseBackendMedals(dynamic raw) {
  final result = <DateTime, MedalType>{};
  if (raw == null) {
    return result;
  }

  MedalType bestMedal(dynamic value) {
    MedalType best = MedalType.none;
    void consider(MedalType candidate) {
      if (_medalPriority[candidate]! > _medalPriority[best]!) {
        best = candidate;
      }
    }

    if (value is List) {
      for (final entry in value) {
        consider(_medalFromEntry(entry));
      }
    } else {
      consider(_medalFromEntry(value));
    }
    return best;
  }

  if (raw is Map) {
    raw.forEach((key, value) {
      final parsedDate = _parseDate(key);
      if (parsedDate == null) return;
      result[dateOnly(parsedDate)] = bestMedal(value);
    });
    return result;
  }

  if (raw is Iterable) {
    for (final entry in raw) {
      if (entry is! Map) {
        continue;
      }
      final parsedDate = _parseDate(
        entry['timestamp'] ?? entry['date'] ?? entry['day'],
      );
      if (parsedDate == null) {
        continue;
      }
      final medalData =
          entry['medal'] ?? entry['medals'] ?? entry['entries'] ?? entry['data'];
      result[dateOnly(parsedDate)] = bestMedal(medalData);
    }
  }

  return result;
}

DateTime? _parseDate(dynamic value) {
  if (value is DateTime) {
    return value;
  }
  if (value == null) {
    return null;
  }
  try {
    return DateTime.parse(value.toString());
  } catch (_) {
    return null;
  }
}

MedalType _medalFromEntry(dynamic entry) {
  if (entry is Map) {
    final code = entry['grade'] ?? entry['medal'] ?? entry['type'] ?? entry['value'];
    return medalTypeFromCode(code?.toString());
  }
  if (entry is String) {
    return medalTypeFromCode(entry);
  }
  return MedalType.none;
}

class UserProfileSyncService {
  UserProfileSyncService._();

  static final UserProfileSyncService instance = UserProfileSyncService._();

  final ProfileApi _profileApi = ProfileApi();
  final UserProfileInfoStorage _infoStorage = UserProfileInfoStorage.instance;
  final UserProfileStorage _photoStorage = UserProfileStorage.instance;
  final MedalHistoryRepository _medalRepository =
      MedalHistoryRepository.instance;

  Future<void> syncAll({
    required String token,
    required String username,
  }) async {
    try {
      _medalRepository.setActiveUser(username);
    } catch (_) {
      // ignore
    }

    final result = await _profileApi.fetchAllData(token: token);
    if (!result.isSuccess || result.data == null) {
      return;
    }

    final data = result.data!;
    if (data.containsKey('medals')) {
      final parsedMedals = parseBackendMedals(data['medals']);
      _medalRepository.replaceAll(parsedMedals);
    }
    final scoreRaw = data['score'];
    if (scoreRaw is num) {
      UserStatsRepository.instance.syncFromScore(scoreRaw.toInt());
    } else if (scoreRaw is String) {
      final parsed = int.tryParse(scoreRaw);
      if (parsed != null) {
        UserStatsRepository.instance.syncFromScore(parsed);
      }
    }
    final fieldSource = data['fields'] is Map ? data['fields'] as Map : data;
    final normalizedFields = <String, dynamic>{};
    if (fieldSource is Map) {
      fieldSource.forEach((key, value) {
        final attrKey = key.toString();
        final fieldId = frontendFieldForAttribute(attrKey);
        if (fieldId != null) {
          normalizedFields[fieldId] = value;
        }
      });
    }
    final fieldsToPersist = <String, String>{};

    for (final field in kUserProfileFields) {
      final value = normalizedFields[field.id];
      if (value is String) {
        fieldsToPersist[field.id] = value;
      } else if (value != null) {
        fieldsToPersist[field.id] = value.toString();
      }
    }

    if (fieldsToPersist.isNotEmpty) {
      await _infoStorage.setFields(username, fieldsToPersist);
    }

    final onboardingAnswers = data['onboarding_answers'];
    if (onboardingAnswers != null) {
      await _infoStorage.setField(
        username,
        'onboarding_answers',
        onboardingAnswers.toString(),
      );
    }

    final profilePic = data['profile_pic'];
    if (profilePic is String && profilePic.isNotEmpty) {
      try {
        final normalized = profilePic.contains(',')
            ? profilePic.split(',').last
            : profilePic;
        final bytes = base64Decode(normalized);
        await _photoStorage.saveProfileImageBytes(bytes, username: username);
      } catch (_) {
        // ignore invalid pic
      }
    }
  }
}
