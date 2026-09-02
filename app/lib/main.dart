import 'package:flutter/material.dart';

import 'api.dart';
import 'call_center.dart';
import 'message_notifier.dart';
import 'models.dart';
import 'offline_api.dart';
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

class _KiteAppState extends State<KiteApp> {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  bool _pushed = false;

  @override
  void initState() {
    super.initState();
    // Sonde de connectivité : l'indicateur En ligne / Hors ligne (barre
    // d'onglets) reflète l'état réel du serveur Go.
    ServerStatus.instance.start(widget.api);
    // Écoute globale des appels entrants (WebSocket/SSE serveur ou flux local).
    CallCenter.instance.start(widget.api);
    CallCenter.instance.current.addListener(_onIncomingCall);
    ScheduledReminderCenter.instance.start(widget.api);
    ScheduledReminderCenter.instance.next.addListener(_onScheduledReminder);
    // Notifications locales de messages entrants (ignorées si muettes).
    MessageNotifier.instance.start(widget.api, meId: widget.api.meId);
    MessageNotifier.instance.last.addListener(_onMessageNotification);
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
  void dispose() {
    ServerStatus.instance.stop();
    CallCenter.instance.current.removeListener(_onIncomingCall);
    ScheduledReminderCenter.instance.next.removeListener(_onScheduledReminder);
    MessageNotifier.instance.last.removeListener(_onMessageNotification);
    MessageNotifier.instance.stop();
    super.dispose();
  }

  /// Popup (snackbar) quand un message entrant est notifiable
  /// (non muet, conversation non ouverte).
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
    return MaterialApp(
      navigatorKey: _nav,
      title: 'Kite',
      debugShowCheckedModeBanner: false,
      theme: kiteDarkTheme(),
      darkTheme: kiteDarkTheme(),
      themeMode: ThemeMode.dark,
      home: HomeShell(api: widget.api),
    );
  }
}
