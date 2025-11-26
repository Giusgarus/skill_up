import 'package:flutter_test/flutter_test.dart';

import 'package:skill_up/features/home/data/medal_history_repository.dart';
import 'package:skill_up/features/home/domain/medal_utils.dart';
import 'package:skill_up/features/profile/data/user_profile_sync_service.dart';

void main() {
  test('parseBackendMedals extracts strongest medal per day', () {
    final parsed = parseBackendMedals({
      '2024-05-01': [
        {'grade': 'B'},
        {'grade': 'G'},
      ],
      '2024-05-02': [
        {'medal': 'S'}
      ],
      'invalid-date': [
        {'grade': 'G'}
      ],
    });

    expect(parsed[DateTime(2024, 5, 1)], MedalType.gold);
    expect(parsed[DateTime(2024, 5, 2)], MedalType.silver);
    expect(parsed.containsKey(DateTime(2024, 1, 1)), isFalse);
  });

  test('replaceAll syncs medals for the active user', () {
    const username = 'medal_tester';
    final repo = MedalHistoryRepository.instance;
    repo.setActiveUser(username);
    repo.setMedalForDay(DateTime(2024, 5, 3), MedalType.bronze);

    final parsed = parseBackendMedals({
      '2024-05-01': [
        {'grade': 'B'}
      ],
      '2024-05-03': [
        {'grade': 'G'}
      ],
    });
    repo.replaceAll(parsed);

    final medals = repo.allMedals();
    expect(medals[DateTime(2024, 5, 1)], MedalType.bronze);
    expect(medals[DateTime(2024, 5, 3)], MedalType.gold);

    repo.clearForUser(username);
  });
}
