import 'package:flutter/material.dart';

import '../chat_lock.dart';
import '../formats.dart';
import '../theme.dart';
import '../ui/avatar.dart';

/// Feuille « Infos conversation » : en-tête (avatar, nom, membres), galerie
/// médias, favoris, thème, blocage, signalement, verrou, biométrie,
/// éphémères, notifications. L'écran fournit les données et callbacks ;
/// ce module ne possède que la présentation.
class ChatInfoSheet {
  ChatInfoSheet._();

  static void show(
    BuildContext context, {
    required String chatName,
    required bool isGroup,
    required List<String> memberIds,
    required List<String> adminIds,
    required String chatId,
    required String Function(String id) senderName,
    required VoidCallback onMedia,
    required VoidCallback onStarred,
    required VoidCallback onWallpaper,
    required bool isBlocked,
    required bool lockBioAvailable,
    required VoidCallback onToggleBlock,
    required VoidCallback onReport,
    required VoidCallback onRemoveLock,
    required VoidCallback onArmLock,
    required VoidCallback onToggleBiometrics,
    required VoidCallback onDisappearing,
    required int disappearing,
    required VoidCallback onNotifications,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        // Scrollable : toutes les tuiles restent accessibles sur petit écran
        // (même mécanisme que le menu contextuel).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    KiteAvatar(name: chatName, group: isGroup, large: true),
                    const SizedBox(height: 10),
                    Text(chatName,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                    Text(
                      isGroup ? '${memberIds.length} membres' : 'en ligne',
                      style: TextStyle(color: KiteColors.muted),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: KiteColors.border),
              if (isGroup)
                for (final id in memberIds)
                  ListTile(
                    dense: true,
                    leading: KiteAvatar(name: senderName(id), group: false),
                    title: Text(senderName(id)),
                    subtitle: adminIds.contains(id)
                        ? Text('Admin',
                            style: TextStyle(
                                color: KiteColors.accent, fontSize: 11))
                        : null,
                  ),
              ListTile(
                leading:
                    Icon(Icons.photo_library_outlined, color: KiteColors.muted),
                title: const Text('Médias, liens et documents',
                    style: TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onMedia();
                },
              ),
              ListTile(
                leading: Icon(Icons.star_border, color: KiteColors.muted),
                title: const Text('Messages favoris',
                    style: TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onStarred();
                },
              ),
              ListTile(
                leading: Icon(Icons.palette_outlined, color: KiteColors.muted),
                title: const Text('Thème du chat',
                    style: TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onWallpaper();
                },
              ),
              if (!isGroup)
                ListTile(
                  leading: Icon(isBlocked ? Icons.lock_person : Icons.block,
                      color: isBlocked ? Colors.redAccent : KiteColors.muted),
                  title: Text(isBlocked ? 'Débloquer le contact' : 'Bloquer',
                      style: const TextStyle(fontSize: 14.5)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onToggleBlock();
                  },
                ),
              ListTile(
                leading: Icon(Icons.flag_outlined, color: KiteColors.muted),
                title: const Text('Signaler', style: TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onReport();
                },
              ),
              ListTile(
                leading: Icon(
                  ChatLockStore.instance.isLocked(chatId)
                      ? Icons.lock
                      : Icons.lock_outline,
                  color: ChatLockStore.instance.isLocked(chatId)
                      ? KiteColors.accent
                      : KiteColors.muted,
                ),
                title: Text(
                  ChatLockStore.instance.isLocked(chatId)
                      ? 'Retirer le verrou de la discussion'
                      : 'Verrouiller la discussion',
                  style: const TextStyle(fontSize: 14.5),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  if (ChatLockStore.instance.isLocked(chatId)) {
                    onRemoveLock();
                  } else {
                    onArmLock();
                  }
                },
              ),
              if (lockBioAvailable && ChatLockStore.instance.isLocked(chatId))
                ListTile(
                  leading: Icon(Icons.fingerprint,
                      color: ChatLockStore.instance.biometricsFor(chatId)
                          ? KiteColors.accent
                          : KiteColors.muted),
                  title: Text(
                      ChatLockStore.instance.biometricsFor(chatId)
                          ? 'Biométrie pour cette discussion : activée'
                          : 'Biométrie pour cette discussion',
                      style: const TextStyle(fontSize: 14.5)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    onToggleBiometrics();
                  },
                ),            ListTile(
              leading: Icon(Icons.timer_outlined,
                  color: KiteColors.muted),
              title: Text(
                disappearing > 0
                    ? 'Messages éphémères : ${kiteDisappearingLabel(disappearing)}'
                    : 'Messages éphémères',
                style: const TextStyle(fontSize: 14.5),
              ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onDisappearing();
                },
              ),
              ListTile(
                leading: Icon(Icons.chevron_right, color: KiteColors.muted),
                title: const Text('Notifications',
                    style: TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onNotifications();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
