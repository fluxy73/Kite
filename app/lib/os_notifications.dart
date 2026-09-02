import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'message_notifier.dart';

/// Notifications OS (bannière système quand l'app est en arrière-plan :
/// processus vivant mais sans fenêtre au premier plan). En premier plan,
/// les notifications restent des snackbars in-app gérées par main.dart.
///
/// Toutes les méthodes sont tolérantes aux pannes : si l'init échoue
/// (permission refusée, plateforme sans support plugin), [available] reste
/// faux et l'app continue avec les snackbars seules — jamais de crash.
class OsNotifications {
  OsNotifications._();

  static final OsNotifications instance = OsNotifications._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// true si les notifications OS sont utilisables sur cette plateforme.
  bool get available => _initialized;

  /// Plateformes où l'app peut passer en arrière-plan au sens strict
  /// (bannière système utile). Sur le web, on garde les snackbars.
  static bool get platformSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS);

  /// ID de notification stable par conversation (une bannière par chat,
  /// remplacée à chaque message).
  static int _idFor(String chatId) {
    var h = 0;
    for (final c in chatId.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  static const _channelId = 'kite_messages';

  /// Flux des appuis sur une notification OS (payload = chatId).
  final StreamController<String> _taps = StreamController.broadcast();
  Stream<String> get taps => _taps.stream;

  Future<void> init() async {
    if (_initialized || !platformSupported) return;
    try {
      const darwinInit = DarwinInitializationSettings();
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: darwinInit,
        macOS: darwinInit,
        linux: LinuxInitializationSettings(defaultActionName: 'Ouvrir'),
        windows: WindowsInitializationSettings(
          appName: 'Kite',
          appUserModelId: 'dev.kite.app',
          guid: '8f1a4c3e-9d2b-4f6a-a1c5-3e7b9d0f2a64',
        ),
      );
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (resp) {
          final chatId = resp.payload;
          if (chatId != null && chatId.isNotEmpty) _taps.add(chatId);
        },
      );

      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final granted = await android?.requestNotificationsPermission();
        if (granted == false) {
          return; // permission refusée : snackbars seules
        }
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            'Messages',
            description: 'Messages entrants Kite',
            importance: Importance.high,
          ),
        );
      }
      if (Platform.isIOS || Platform.isMacOS) {
        final grantedIOS = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        if (Platform.isIOS && grantedIOS == false) return;
        final grantedMac = await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        if (Platform.isMacOS && grantedMac == false) return;
      }

      _initialized = true;
    } catch (_) {
      // Plugin indisponible (tests, plateforme sans implémentation, etc.) :
      // on garde les snackbars in-app.
      _initialized = false;
    }
  }

  /// Affiche une notification OS pour un message entrant.
  Future<void> show(MessageNotification n) async {
    if (!_initialized) return;
    final body = n.chatName.isEmpty ? n.body : '${n.chatName} · ${n.body}';
    try {
      await _plugin.show(
        id: _idFor(n.chatId),
        title: n.senderName,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Messages',
            channelDescription: 'Messages entrants Kite',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
        payload: n.chatId,
      );
    } catch (_) {
      // Best-effort : une bannière ratée ne doit rien casser.
    }
  }

  /// La bannière d'une conversation s'efface quand l'utilisateur l'ouvre.
  Future<void> cancelForChat(String chatId) async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(id: _idFor(chatId));
    } catch (_) {}
  }
}
