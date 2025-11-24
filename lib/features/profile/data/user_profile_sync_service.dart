import 'dart:convert';

import '../../home/data/medal_history_repository.dart';
import '../domain/user_profile_fields.dart';
import 'profile_api.dart';
import 'profile_field_mapping.dart';
import 'user_profile_info_storage.dart';
import 'user_profile_storage.dart';

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
