import 'package:flutter/material.dart';

import '../chat_lock.dart';
import '../theme.dart';

/// Écran de réglage du verrou d'app : pose via la porte [AppLockGate].
///
/// Le déverrouillage quotidien est géré par la porte intégrée dans
/// `KiteApp` (démarrage + retour au premier plan) ; le retrait se fait
/// via [confirmRemoval] (code requis, vérifié par le hash).
class AppLockScreen extends StatelessWidget {
  const AppLockScreen({super.key});

  /// Pose du verrou : porte en mode setup (code + confirmation + offre
  /// biométrique), puis fermeture de l'écran.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KiteColors.bg,
      appBar: AppBar(title: const Text('Verrouillage de l\'app')),
      body: AppLockGate(
        mode: AppLockGateMode.setup,
        onDone: () {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Verrou de l\'app activé'),
              duration: Duration(seconds: 2)));
        },
      ),
    );
  }

  /// Retrait du verrou : demande le code et le vérifie côté store.
  static Future<void> confirmRemoval(BuildContext context) async {
    final ctrl = TextEditingController();
    final store = ChatLockStore.instance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Retirer le verrou de l\'app',
            style: TextStyle(color: KiteColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Saisissez le code pour confirmer.',
                style: TextStyle(color: KiteColors.muted)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              style: const TextStyle(color: KiteColors.fg, letterSpacing: 8),
              decoration: const InputDecoration(
                  counterText: '', hintText: '••••'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (store.removeAppLock(ctrl.text)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Verrou de l\'app retiré'),
          duration: Duration(seconds: 2)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Code incorrect — verrou toujours actif'),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 2)));
    }
  }
}
