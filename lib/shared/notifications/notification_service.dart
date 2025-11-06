import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../features/auth/data/services/auth_api.dart';
import 'notification_api.dart';

/// Centralizes Firebase Cloud Messaging setup and server registration.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final NotificationApi _api = NotificationApi();
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  AuthSession? _activeSession;
  StreamSubscription<String>? _tokenRefreshSubscription;
  bool _initialized = false;

  static const AndroidNotificationChannel _defaultChannel =
      AndroidNotificationChannel(
        'skill_up_general',
        'SkillUp',
        description: 'General updates from SkillUp',
        importance: Importance.high,
      );

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _messaging.setAutoInitEnabled(true);
      await _messaging.requestPermission();
      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _localNotifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (_) {},
        onDidReceiveBackgroundNotificationResponse: (_) {},
      );
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.createNotificationChannel(_defaultChannel);

      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    }

    FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedMessage);
    _initialized = true;
  }

  Future<void> registerSession(AuthSession session) async {
    if (!await _ensureFirebaseReady()) {
      return;
    }
    _activeSession = session;

    await _registerCurrentToken();
    _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh
        .listen((token) async {
          final activeSession = _activeSession;
          if (activeSession == null) {
            return;
          }
          await _api.registerDevice(
            username: activeSession.username,
            sessionToken: activeSession.token,
            deviceToken: token,
            platform: defaultTargetPlatform == TargetPlatform.android
                ? 'android'
                : 'unknown',
          );
        });
  }

  Future<void> _registerCurrentToken() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final token = await _messaging.getToken();
      final activeSession = _activeSession;
      if (token == null || activeSession == null) {
        return;
      }
      await _api.registerDevice(
        username: activeSession.username,
        sessionToken: activeSession.token,
        deviceToken: token,
        platform: 'android',
      );
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) {
      return;
    }
    final androidDetails = AndroidNotificationDetails(
      _defaultChannel.id,
      _defaultChannel.name,
      channelDescription: _defaultChannel.description,
      importance: Importance.high,
      priority: Priority.high,
    );
    final details = NotificationDetails(android: androidDetails);
    _localNotifications.show(
      notification.hashCode,
      notification.title ?? 'SkillUp',
      notification.body ?? '',
      details,
      payload: message.data.isEmpty ? null : message.data.toString(),
    );
  }

  void _handleOpenedMessage(RemoteMessage message) {
    // Currently no deep-linking requirements. Keep hook for future use.
    if (kDebugMode) {
      debugPrint('Notification opened: ${message.messageId}');
    }
  }

  Future<bool> _ensureFirebaseReady() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      return true;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Firebase not ready for notifications: $error');
        debugPrint(stackTrace.toString());
      }
      return false;
    }
  }

  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _api.close();
  }
}
