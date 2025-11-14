import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../features/auth/data/services/auth_api.dart';
import '../../firebase_options.dart';
import 'notification_api.dart';

const String _webPushKey = String.fromEnvironment(
  'FIREBASE_WEB_PUSH_KEY',
  defaultValue: '',
);

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {
  NotificationService.instance.handleBackgroundNotificationResponse(
    notificationResponse,
  );
}

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
  bool _permissionsRequested = false;
  bool _permissionsGranted = false;
  bool _registrationInProgress = false;

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
    if (!await _ensureFirebaseReady()) {
      return;
    }

    if (_fcmSupported) {
      await _messaging.setAutoInitEnabled(true);
    } else if (kDebugMode) {
      debugPrint('Firebase Messaging is not supported on this platform yet.');
    }

    if (!kIsWeb) {
      await _configureLocalNotifications();
    }

    if (_fcmSupported) {
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedMessage);
    }

    _initialized = true;
  }

  bool get shouldPromptForPermission => _fcmSupported && !_permissionsRequested;

  bool get permissionsGranted => !_fcmSupported || _permissionsGranted;

  Future<bool> requestPlatformPermissions() async {
    if (!_fcmSupported) {
      return false;
    }
    if (_permissionsRequested) {
      return _permissionsGranted;
    }
    final granted = await _requestPermissions();
    _permissionsRequested = true;
    _permissionsGranted = granted;
    return granted;
  }

  Future<void> registerSession(AuthSession session) async {
    if (!_fcmSupported) {
      if (kDebugMode) {
        debugPrint('Skipping device registration: FCM unsupported on this platform.');
      }
      return;
    }
    if (!await _ensureFirebaseReady()) {
      return;
    }
    final existingSession = _activeSession;
    final isSameSession = existingSession != null &&
        existingSession.token == session.token &&
        existingSession.username == session.username;
    if (isSameSession) {
      if (_registrationInProgress) {
        if (kDebugMode) {
          debugPrint('NotificationService: registration already running.');
        }
        return;
      }
      if (_tokenRefreshSubscription != null) {
        if (kDebugMode) {
          debugPrint('NotificationService: active session already registered.');
        }
        return;
      }
    }
    _registrationInProgress = true;
    try {
      _activeSession = session;

      if (!_permissionsGranted) {
        await requestPlatformPermissions();
      }
      if (!_permissionsGranted) {
        if (kDebugMode) {
          debugPrint('Notifications disabled; skipping device registration.');
        }
        return;
      }

      await _registerCurrentToken();
      _tokenRefreshSubscription ??= _messaging.onTokenRefresh.listen(
        _sendTokenToServer,
      );
    } finally {
      _registrationInProgress = false;
    }
  }

  Future<void> _registerCurrentToken() async {
    if (!_fcmSupported) {
      return;
    }
    final token = await _getPlatformToken();
    if (token == null) {
      return;
    }
    await _sendTokenToServer(token);
  }

  Future<String?> _getPlatformToken() async {
    if (!_fcmSupported) {
      return null;
    }
    try {
      if (kIsWeb) {
        final vapidKey = _webPushKey.isEmpty ? null : _webPushKey;
        return _messaging.getToken(vapidKey: vapidKey);
      }
      return _messaging.getToken();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Unable to fetch FCM token: $error');
        debugPrint(stackTrace.toString());
      }
      return null;
    }
  }

  Future<void> _sendTokenToServer(String token) async {
    final activeSession = _activeSession;
    if (activeSession == null) {
      if (kDebugMode) {
        debugPrint(
          'NotificationService: no active session, skipping token registration.',
        );
      }
      return;
    }
    await _api.registerDevice(
      username: activeSession.username,
      sessionToken: activeSession.token,
      deviceToken: token,
      platform: _platformLabel,
    );
  }

  Future<bool> _requestPermissions() async {
    if (!_fcmSupported) {
      return false;
    }
    try {
      NotificationSettings settings;
      if (kIsWeb) {
        settings = await _messaging.requestPermission();
      } else {
        settings = await _messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
        if (_isApplePlatform) {
          await _messaging.setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
        }
      }
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Notification permission request failed: $error');
        debugPrint(stackTrace.toString());
      }
      return false;
    }
  }

  Future<void> _configureLocalNotifications() async {
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      windows: WindowsInitializationSettings(
        appName: 'SkillUp',
        appUserModelId: 'com.app.skillUp',
        guid: '3a76e08c-50d1-4e7c-9369-5fb8d223e940',
      ),
    );
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleLocalNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(_defaultChannel);
    }
  }

  void _handleLocalNotificationResponse(
    NotificationResponse notificationResponse,
  ) {
    handleBackgroundNotificationResponse(notificationResponse);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    if (kIsWeb) {
      if (kDebugMode) {
        debugPrint('Web foreground message: ${message.messageId}');
      }
      return;
    }
    final notification = message.notification;
    if (notification == null) {
      return;
    }
    final details = _buildNotificationDetails();
    if (details == null) {
      return;
    }
    _localNotifications.show(
      notification.hashCode,
      notification.title ?? 'SkillUp',
      notification.body ?? '',
      details,
      payload: message.data.isEmpty ? null : message.data.toString(),
    );
  }

  NotificationDetails? _buildNotificationDetails() {
    if (kIsWeb || !_fcmSupported) {
      return null;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final androidDetails = AndroidNotificationDetails(
          _defaultChannel.id,
          _defaultChannel.name,
          channelDescription: _defaultChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        );
        return NotificationDetails(android: androidDetails);
      case TargetPlatform.iOS:
        return const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
      case TargetPlatform.macOS:
        return const NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
      case TargetPlatform.windows:
        return const NotificationDetails(
          windows: WindowsNotificationDetails(),
        );
      default:
        return null;
    }
  }

  void _handleOpenedMessage(RemoteMessage message) {
    if (kDebugMode) {
      debugPrint('Notification opened: ${message.messageId}');
    }
  }

  void handleBackgroundNotificationResponse(
    NotificationResponse notificationResponse,
  ) {
    if (kDebugMode) {
      debugPrint(
        'Notification tapped: '
        '${notificationResponse.notificationResponseType} '
        '${notificationResponse.payload}',
      );
    }
  }

  Future<bool> _ensureFirebaseReady() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
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

  String get _platformLabel {
    if (kIsWeb) {
      return 'web';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      default:
        return 'unknown';
    }
  }

  bool get _isApplePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _fcmSupported =>
      kIsWeb ||
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS));

  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _api.close();
  }
}
