import 'package:flutter/foundation.dart';
import 'package:skill_up/features/auth/data/services/auth_api.dart';
import 'package:skill_up/shared/notifications/notification_service.dart';

/// Registers the current session with the notification backend without
/// surfacing transient failures to the UI.
Future<void> registerNotificationsForSession(AuthSession session) async {
  try {
    await NotificationService.instance.registerSession(session);
  } catch (error, stackTrace) {
    if (kDebugMode) {
      debugPrint('Notification registration failed: $error');
      debugPrint(stackTrace.toString());
    }
  }
}
