import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'spring_reaction_bar.dart';

/// Menu contextuel au appui long sur un message : barre de réactions +
/// actions (répondre, copier, modifier, épingler, favori, traduire, infos,
/// suppression). L'écran fournit les callbacks ; ce module ne possède que
/// la présentation.
class MessageMenu {
  MessageMenu._();

  static void show(
    BuildContext context,
    Message m, {
    required String meId,
    required void Function(String emoji) onReact,
    required VoidCallback onReply,
    required VoidCallback onCopy,
    required VoidCallback onEdit,
    required VoidCallback onPin,
    required VoidCallback onToggleStar,
    required VoidCallback onTranslate,
    required VoidCallback onInfo,
    required void Function(String mode) onDelete,
  }) {
    final mine = m.isMine(meId);
    final copyable = m.type == 'text';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        // Scrollable : le menu reste accessible même sur petit écran.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SpringReactionBar(
                onPick: (e) {
                  Navigator.pop(sheetCtx);
                  onReact(e);
                },
              ),
            ),
            Divider(height: 1, color: KiteColors.border),
            item(sheetCtx, Icons.reply, 'Répondre', onReply),
            if (copyable)
              item(sheetCtx, Icons.copy_outlined, 'Copier', onCopy),
            if (mine && copyable)
              item(sheetCtx, Icons.edit_outlined, 'Modifier', onEdit),
            item(sheetCtx, Icons.push_pin_outlined, 'Épingler', onPin),
            item(
              sheetCtx,
              m.starredFor(meId) ? Icons.star : Icons.star_border,
              m.starredFor(meId)
                  ? 'Retirer des favoris'
                  : 'Ajouter aux favoris',
              onToggleStar,
            ),
            item(sheetCtx, Icons.translate, 'Traduire', onTranslate),
            item(sheetCtx, Icons.info_outline, 'Informations', onInfo),
            item(
              sheetCtx,
              Icons.delete_outline,
              mine ? 'Supprimer pour tout le monde' : 'Supprimer pour moi',
              () => onDelete(mine ? 'all' : 'me'),
            ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget item(
      BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon,
          color: label.startsWith('Supprimer')
              ? KiteColors.danger
              : KiteColors.accent),
      title: Text(
        label,
        style: TextStyle(
            color: label.startsWith('Supprimer')
                ? KiteColors.danger
                : KiteColors.fg),
      ),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }
}
