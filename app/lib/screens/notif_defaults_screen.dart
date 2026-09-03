import 'package:flutter/material.dart';

import '../api.dart';
import '../message_notifier.dart';
import '../theme.dart';

/// Éditeur de préférences de notification (priorité, son, aperçu), partagé
/// entre l'écran des défauts globaux et le dialogue par conversation.
class NotifPrefsEditor extends StatelessWidget {
  const NotifPrefsEditor({
    super.key,
    required this.prefs,
    required this.onChanged,
  });

  final NotifPrefs prefs;
  final ValueChanged<NotifPrefs> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Priorité',
            style: TextStyle(color: KiteColors.muted, fontSize: 12)),
        RadioGroup<NotifPriority>(
          groupValue: prefs.priority,
          onChanged: (v) => onChanged(prefs.copyWith(priority: v)),
          child: const Column(
            children: [
              RadioListTile<NotifPriority>(
                dense: true,
                value: NotifPriority.low,
                title: Text('Basse (silencieuse)'),
              ),
              RadioListTile<NotifPriority>(
                dense: true,
                value: NotifPriority.normal,
                title: Text('Normale'),
              ),
              RadioListTile<NotifPriority>(
                dense: true,
                value: NotifPriority.high,
                title: Text('Haute (urgente)'),
              ),
            ],
          ),
        ),
        const Divider(color: KiteColors.border),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Son'),
          value: prefs.soundOn,
          onChanged: (v) => onChanged(prefs.copyWith(sound: v)),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Aperçu du message'),
          subtitle: const Text('Masque le texte dans la notification',
              style: TextStyle(fontSize: 12, color: KiteColors.muted)),
          value: prefs.previewOn,
          onChanged: (v) => onChanged(prefs.copyWith(preview: v)),
        ),
      ],
    );
  }
}

/// Défauts de notification pour toutes les conversations sans réglage
/// propre (priorité, son, aperçu). Les préférences par conversation
/// (fiche infos) priment sur ces défauts, qui priment eux-mêmes sur les
/// défauts de l'app.
class NotifDefaultsScreen extends StatefulWidget {
  const NotifDefaultsScreen({super.key, required this.api});

  final KiteApi api;

  @override
  State<NotifDefaultsScreen> createState() => _NotifDefaultsScreenState();
}

class _NotifDefaultsScreenState extends State<NotifDefaultsScreen> {
  NotifPrefs _prefs = const NotifPrefs();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Le shell transporte les défauts globaux (même source que le notifier).
    try {
      final shell = await widget.api.fetchAppShell();
      if (!mounted) return;
      setState(() {
        _prefs = shell.notifDefaults;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    try {
      await widget.api.setNotifDefaults(prefs: _prefs.isEmpty ? null : _prefs);
      // Le notifier consomme ces défauts pour chaque notification.
      MessageNotifier.instance.globalDefaults = _prefs;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_prefs.isEmpty
              ? 'Défauts réinitialisés'
              : 'Défauts enregistrés'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enregistrement impossible')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KiteColors.bg,
      appBar: AppBar(
        backgroundColor: KiteColors.bg,
        title: const Text('Notifications'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Défauts pour toutes les conversations. Un réglage propre '
                  'à une conversation (fiche infos) prime sur ces défauts.',
                  style: TextStyle(color: KiteColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  decoration: BoxDecoration(
                    color: KiteColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: NotifPrefsEditor(
                    prefs: _prefs,
                    onChanged: (p) => setState(() => _prefs = p),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: KiteColors.accent,
                    foregroundColor: KiteColors.accentInk,
                  ),
                  onPressed: _save,
                  child: const Text('Enregistrer'),
                ),
                TextButton(
                  onPressed: () => setState(() => _prefs = const NotifPrefs()),
                  child: const Text('Réinitialiser'),
                ),
              ],
            ),
    );
  }
}
