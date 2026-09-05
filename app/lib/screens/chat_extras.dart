import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Écrans satellites de la fiche info : galerie média + messages favoris,
/// visionneuse, sélecteur de thème et signalement.
///
/// Toutes les données proviennent de la liste de messages réelle passée en
/// paramètre (aucun mock) ; les actions remontent via callbacks.

/// Palette de thèmes de conversation (clé -> couleurs).
const Map<String, ({Color start, Color end, String label})> kWallpapers = {
  '': (start: Color(0xFF101010), end: Color(0xFF101010), label: 'Défaut'),
  'midnight': (start: Color(0xFF0D1B2A), end: Color(0xFF1B263B), label: 'Minuit'),
  'forest': (start: Color(0xFF0B2818), end: Color(0xFF14532D), label: 'Forêt'),
  'sunset': (start: Color(0xFF2D132C), end: Color(0xFF7B2D43), label: 'Coucher'),
  'ocean': (start: Color(0xFF06283D), end: Color(0xFF1363DF), label: 'Océan'),
  'rose': (start: Color(0xFF2B0A3D), end: Color(0xFF8E2DE2), label: 'Rose'),
};

const List<String> kWallpaperKeys = ['', 'midnight', 'forest', 'sunset', 'ocean', 'rose'];

/// Galerie « Médias, liens et documents » + « Messages favoris » :
/// onglets extraits réellement des messages du chat.
class MediaGalleryScreen extends StatelessWidget {
  const MediaGalleryScreen({
    super.key,
    required this.messages,
    required this.isMine,
    this.onOpen,
  });

  final List<Message> messages;
  final bool Function(Message) isMine;
  final void Function(BuildContext, Message)? onOpen;

  static const List<String> _mediaTypes = [
    'image', 'video', 'document', 'audio', 'voice',
    'videonote', 'gif', 'sticker', 'contact', 'location',
  ];

  List<Message> get _media =>
      messages.where((m) => _mediaTypes.contains(m.type) && !m.deleted).toList();
  List<Message> get _starred =>
      messages.where((m) => m.starredBy.isNotEmpty && !m.deleted).toList();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: KiteColors.bg,
        appBar: AppBar(
          title: const Text('Médias et favoris'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Médias'),
            Tab(text: 'Favoris'),
          ]),
        ),
        body: TabBarView(children: [
          if (_media.isEmpty)
            const _Empty('Aucun média dans cette discussion')
          else
            GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
              itemCount: _media.length,
              itemBuilder: (ctx, i) => _MediaTile(
                  message: _media[i], onTap: () => onOpen?.call(ctx, _media[i])),
            ),
          if (_starred.isEmpty)
            const _Empty('Aucun message favori')
          else
            ListView.builder(
              itemCount: _starred.length,
              itemBuilder: (ctx, i) => _StarredTile(
                  message: _starred[i], isMine: isMine(_starred[i])),
            ),
        ]),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.message, this.onTap});
  final Message message;
  final VoidCallback? onTap;

  IconData get _icon => switch (message.type) {
        'video' => Icons.videocam,
        'document' => Icons.insert_drive_file,
        'audio' || 'voice' => Icons.mic,
        'videonote' => Icons.video_camera_back_outlined,
        'contact' => Icons.contact_page_outlined,
        'location' => Icons.location_on_outlined,
        _ => Icons.image_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: KiteColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: KiteColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_icon, color: KiteColors.accent),
            const SizedBox(height: 4),
            Text(
              (message.media?['name'] as String?) ?? message.type,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: KiteColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _StarredTile extends StatelessWidget {
  const _StarredTile({required this.message, required this.isMine});
  final Message message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final subtitle = message.text.isEmpty
        ? (message.media?['name'] as String?) ?? message.type
        : message.text;
    return ListTile(
      leading: const Icon(Icons.star, color: KiteColors.accent),
      title: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(isMine ? 'Vous' : message.senderId,
          style: const TextStyle(fontSize: 11.5)),
    );
  }
}

/// Visionneuse plein écran d'une pièce jointe (métadonnées réelles du message).
class MediaViewerScreen extends StatelessWidget {
  const MediaViewerScreen({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final name = (m.media?['name'] as String?) ?? m.type;
    final rows = <(String, String)>[
      ('Type', m.type),
      ('Nom', name),
      ('Envoyé le', DateTime.fromMillisecondsSinceEpoch(m.createdAt).toString().substring(0, 16)),
      if (m.media?['size'] != null) ('Taille', m.media!['size'].toString()),
      if (m.media?['duration'] != null)
        ('Durée', "${m.media!['duration']} s"),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_iconFor(m.type), size: 84, color: Colors.white70),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (k, v) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text('$k : $v',
                          style: const TextStyle(color: Colors.white, fontSize: 13.5)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String type) => switch (type) {
        'video' => Icons.videocam,
        'document' => Icons.insert_drive_file,
        'audio' || 'voice' => Icons.mic,
        'contact' => Icons.contact_page_outlined,
        'location' => Icons.location_on_outlined,
        _ => Icons.image_outlined,
      };
}

/// Sélecteur de thème du chat : retourne la clé choisie ('' = défaut),
/// ou null si abandon. Le choix est appliqué par l'appelant via l'API.
Future<String?> showWallpaperPicker(BuildContext context, String current) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: KiteColors.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('Thème du chat',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          for (final key in kWallpaperKeys)
            ListTile(
              leading: Container(
                width: 42,
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: LinearGradient(
                      colors: [kWallpapers[key]!.start, kWallpapers[key]!.end]),
                  border: Border.all(color: KiteColors.border),
                ),
              ),
              title: Text(kWallpapers[key]!.label,
                  style: const TextStyle(fontSize: 14.5)),
              trailing: key == current
                  ? const Icon(Icons.check, color: KiteColors.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, key),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Dialogue de signalement : retourne (motif, détails) ou null si abandon.
Future<(String, String)?> showReportDialog(BuildContext context) {
  final reasons = ['Spam', 'Contenu inapproprié', 'Harcèlement', 'Autre'];
  final reasonCtrl = TextEditingController(text: reasons.first);
  final detailsCtrl = TextEditingController();
  return showDialog<(String, String)>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: KiteColors.surface,
      title: const Text('Signaler la conversation',
          style: TextStyle(color: KiteColors.fg)),
      content: StatefulBuilder(
        builder: (ctx, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioGroup<String>(
              groupValue: reasonCtrl.text,
              onChanged: (v) => setDialogState(() => reasonCtrl.text = v ?? reasonCtrl.text),
              child: Column(
                children: [
                  for (final r in reasons)
                    RadioListTile<String>(
                      value: r,
                      title: Text(r, style: const TextStyle(fontSize: 14)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            TextField(
              controller: detailsCtrl,
              maxLines: 2,
              style: const TextStyle(color: KiteColors.fg, fontSize: 13.5),
              decoration: const InputDecoration(
                  hintText: 'Détails (optionnel)',
                  hintStyle: TextStyle(color: KiteColors.muted)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(ctx, (reasonCtrl.text, detailsCtrl.text.trim())),
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          child: const Text('Signaler'),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.inbox_outlined, size: 46, color: KiteColors.muted),
            const SizedBox(height: 10),
            Text(text, style: const TextStyle(color: KiteColors.muted)),
          ],
        ),
      );
}
