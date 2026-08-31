import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

void main() {
  // URL du serveur : --dart-define=KITE_API=http://localhost:8080
  // (émulateur Android : http://10.0.2.2:8080)
  const apiBase = String.fromEnvironment('KITE_API', defaultValue: 'http://localhost:8080');
  runApp(KiteApp(api: KiteApi(apiBase)));
}

class KiteApp extends StatelessWidget {
  const KiteApp({super.key, required this.api});

  final KiteApi api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kite',
      debugShowCheckedModeBanner: false,
      theme: kiteDarkTheme(),
      darkTheme: kiteDarkTheme(),
      themeMode: ThemeMode.dark,
      home: HomeShell(api: api),
    );
  }
}
