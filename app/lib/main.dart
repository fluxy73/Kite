import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'call_center.dart';
import 'chat_lock.dart';
import 'message_notifier.dart';
import 'models.dart';
import 'offline_api.dart';
import 'os_notifications.dart';
import 'reminder_center.dart';
import 'server_status.dart';
import 'screens/home_shell.dart';
import 'screens/incoming_call_screen.dart';
import 'screens/conversation_screen.dart';
import 'theme.dart';

void main() {
  // Mode hors-ligne par défaut : l'app fonctionne seule (données locales).
  // Pour brancher un serveur : --dart-define=KITE_API=http://host:8080
  // (émulateur Android : http://10.0.2.2:8080)
  const apiBase = String.fromEnvironment('KITE_API');
  final api = apiBase.isNotEmpty
      ? KiteApi(apiBase)
      : OfflineApi() as dynamic;
  runApp(KiteApp(api: api));
}

class KiteApp extends StatefulWidget {
  const KiteApp({super.key, required this.api});

  final dynamic api;

  @override
  State<KiteApp> createState() => _KiteAppState();
}

class _KiteAppState extends State<KiteApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  bool _pushed = false;

  /// Verrou d'app : true tant que la porte doit être affichée (démarrage,
  /// retour au premier plan, réglage en cours).
  bool _appLocked = false;
  DateTime _lastUnlock = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Porte d'app au démarrage si un verrou est posé.
    _appLocked = ChatLockStore.instance.appLockEnabled;
    // Sonde de connectivité : l'indicateur En ligne / Hors ligne (barre
    // d'onglets) reflète l'état réel du serveur Go.
    ServerStatus.instance.start(widget.api);
    // Écoute globale des appels entrants (WebSocket/SSE serveur ou flux local).
    CallCenter.instance.start(widget.api);
    CallCenter.instance.current.addListener(_onIncomingCall);
    ScheduledReminderCenter.instance.start(widget.api);
    ScheduledReminderCenter.instance.next.addListener(_onScheduledReminder);
    // Notifications locales de messages entrants (ignorées si muettes) :
    // bannière OS en arrière-plan, snackbar in-app en premier plan.
    MessageNotifier.instance.start(widget.api, meId: widget.api.meId);
    MessageNotifier.instance.last.addListener(_onMessageNotification);
    _initOsNotifications();
  }

  void _onIncomingCall() {
    final call = CallCenter.instance.current.value;
    if (call == null) {
      _pushed = false;
      return;
    }
    if (_pushed) return;
    _pushed = true;
    final nav = _nav.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(api: widget.api, call: call),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Auto-lock d'app au retour au premier plan (comportement bancaire) ;
      // anti-rebond : pas de re-verrouillage juste après un déverrouillage.
      if (ChatLockStore.instance.appLockEnabled &&
          DateTime.now().difference(_lastUnlock).inSeconds > 2) {
        setState(() => _appLocked = true);
      }
      // Auto-lock des conversations déverrouillées (comportement WhatsApp).
      ChatLockStore.instance.lockAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ServerStatus.instance.stop();
    CallCenter.instance.current.removeListener(_onIncomingCall);
    ScheduledReminderCenter.instance.next.removeListener(_onScheduledReminder);
    MessageNotifier.instance.last.removeListener(_onMessageNotification);
    MessageNotifier.instance.stop();
    _osTapSub?.cancel();
    super.dispose();
  }

  Future<void> _initOsNotifications() async {
    await OsNotifications.instance.init();
    if (!OsNotifications.instance.available) return;
    // Bannière OS activée : le notifier route en fonction du cycle de vie.
    MessageNotifier.instance.osShow = OsNotifications.instance.show;
    // Appui sur une bannière → ouvrir la conversation.
    _osTapSub = OsNotifications.instance.taps.listen(_openChatById);
  }

  StreamSubscription<String>? _osTapSub;

  /// Popup (snackbar) quand un message entrant est notifiable au premier
  /// plan (non muet, conversation non ouverte).
  void _onMessageNotification() {
    final n = MessageNotifier.instance.last.value;
    if (n == null) return;
    MessageNotifier.instance.reset();
    final ctx = _nav.currentState?.context;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        backgroundColor: KiteColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n.senderName, style: const TextStyle(fontWeight: FontWeight.w700, color: KiteColors.fg)),
            if (n.chatName.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(n.chatName, style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
            ],
            const SizedBox(height: 4),
            Text(n.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: KiteColors.fg)),
          ],
        ),
        action: SnackBarAction(
          label: 'Ouvrir',
          onPressed: () {
            _openChatById(n.chatId);
          },
        ),
      ),
    );
  }

  Future<void> _openChatById(String chatId) async {
    try {
      final chats = await (widget.api as dynamic).fetchChats() as List<Chat>;
      final chat = chats.where((c) => c.id == chatId).firstOrNull;
      final ctx = _nav.currentState?.context;
      if (chat == null || ctx == null || !ctx.mounted) return;
      OsNotifications.instance.cancelForChat(chatId);
      await Navigator.of(ctx, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => ConversationScreen(api: widget.api, chat: chat)),
      );
    } catch (_) {
      // Chat introuvable : notification expirée, on ignore.
    }
  }

  /// Popup quand un appel planifié arrive dans moins d'une heure (rappel activé).
  void _onScheduledReminder() {
    final sc = ScheduledReminderCenter.instance.next.value;
    if (sc == null) return;
    ScheduledReminderCenter.instance.reset();
    final ctx = _nav.currentState?.context;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Rappel d’appel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sc.title, style: const TextStyle(fontWeight: FontWeight.w600, color: KiteColors.fg)),
            const SizedBox(height: 6),
            Text('Dans moins d’une heure · ${_fmtReminder(sc.scheduledAt)}', style: const TextStyle(color: KiteColors.muted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(sc.kind == 'video' ? 'Appel vidéo' : 'Appel audio', style: const TextStyle(color: KiteColors.muted, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('OK')),
        ],
      ),
    );
  }

  static String _fmtReminder(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final lockOn = ChatLockStore.instance.appLockEnabled;
    final gating = lockOn && _appLocked;
    return MaterialApp(
      navigatorKey: _nav,
      title: 'Kite',
      debugShowCheckedModeBanner: false,
      theme: kiteDarkTheme(),
      darkTheme: kiteDarkTheme(),
      themeMode: ThemeMode.dark,
      home: gating
          ? Scaffold(
              backgroundColor: KiteColors.bg,
              body: AppLockGate(
                mode: AppLockGateMode.unlock,
                authenticator: _appAuthenticator,
                onDone: () {
                  _lastUnlock = DateTime.now();
                  setState(() => _appLocked = false);
                },
              ),
            )
          : HomeShell(api: widget.api),
    );
  }

  /// Injecté par les tests ; production = local_auth.
  BiometricAuthenticator? _appAuthenticator;
}
