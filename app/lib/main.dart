import 'package:flutter/material.dart';

import 'api.dart';
import 'call_center.dart';
import 'reminder_center.dart';
import 'screens/home_shell.dart';
import 'screens/incoming_call_screen.dart';
import 'theme.dart';

void main() {
  // URL du serveur : --dart-define=KITE_API=http://localhost:8080
  // (émulateur Android : http://10.0.2.2:8080)
  const apiBase = String.fromEnvironment('KITE_API', defaultValue: 'http://localhost:8080');
  runApp(KiteApp(api: KiteApi(apiBase)));
}

class KiteApp extends StatefulWidget {
  const KiteApp({super.key, required this.api});

  final KiteApi api;

  @override
  State<KiteApp> createState() => _KiteAppState();
}

class _KiteAppState extends State<KiteApp> {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  bool _pushed = false;

  @override
  void initState() {
    super.initState();
    // Écoute globale des appels entrants via WebSocket/SSE (temps réel).
    CallCenter.instance.start(widget.api);
    CallCenter.instance.current.addListener(_onIncomingCall);
    ScheduledReminderCenter.instance.start(widget.api);
    ScheduledReminderCenter.instance.next.addListener(_onScheduledReminder);
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
    CallCenter.instance.current.removeListener(_onIncomingCall);
    ScheduledReminderCenter.instance.next.removeListener(_onScheduledReminder);
    super.dispose();
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
