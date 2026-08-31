import 'package:flutter/material.dart';

import 'api.dart';
import 'call_center.dart';
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
    super.dispose();
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
