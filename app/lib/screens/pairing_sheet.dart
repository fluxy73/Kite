import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../ui/ui.dart';

/// Feuille de jumelage & découverte de pairs :
/// - « Mon code » : QR d'identité (partageable) ;
/// - « Scanner » : caméra (repli saisie manuelle sans caméra) ;
/// - « À proximité » : radar à pairs avec anneaux pulsés.
///
/// Honnête hors-ligne : sans serveur, le radar détecte les pairs déjà
/// connus de l'app (découverte réseau réelle à venir). La saisie de code
/// fonctionne toujours.
class PairingSheet extends StatefulWidget {
  const PairingSheet({super.key, required this.api, required this.users});

  final KiteApi api;
  final List<User> users;

  /// Ouvre la feuille ; renvoie l'utilisateur à ouvrir en DM (ou null).
  static Future<User?> show(BuildContext context,
      {required KiteApi api, required List<User> users}) {
    return showModalBottomSheet<User?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SafeArea(child: PairingSheet(api: api, users: users)),
    );
  }

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  late final String _myCode;
  final TextEditingController _manual = TextEditingController();
  String? _manualError;

  @override
  void initState() {
    super.initState();
    // Code d'identité court : id sans préfixe + checksum 2 caractères.
    final raw = widget.api.meId.replaceAll(RegExp(r'^u-'), '');
    final sum = raw.codeUnits.fold<int>(0, (a, c) => a + c) % 97;
    _myCode = '$raw-${sum.toString().padLeft(2, '0')}';
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _manual.dispose();
    super.dispose();
  }

  User? _byCode(String code) {
    final norm = code.trim().toLowerCase();
    for (final u in widget.users) {
      if (u.id == norm || u.id.endsWith(norm)) return u;
    }
    return null;
  }

  void _openPeer(User? u) {
    if (u == null) {
      setState(() =>
          _manualError = 'Code inconnu — vérifiez avec votre contact.');
      return;
    }
    Navigator.pop(context, u);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.78,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: KiteColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Se connecter à quelqu’un',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: KiteColors.fg)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TabBar(
              controller: _tabs,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: KiteColors.accent,
              unselectedLabelColor: KiteColors.muted,
              indicatorColor: KiteColors.accent,
              tabs: const [
                Tab(text: 'Mon code'),
                Tab(text: 'Scanner'),
                Tab(text: 'À proximité'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _myQrTab(),
                _scanTab(),
                PeerRadarTab(
                  api: widget.api,
                  users: widget.users,
                  onPick: _openPeer,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Onglet 1 : mon QR ----------

  Widget _myQrTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: KiteColors.softShadow(),
            ),
            child: QrImageView(
              data: 'kite://peer/$_myCode',
              size: 200,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square, color: Color(0xFF111418)),
              dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF111418)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Votre code de jumelage',
              style: TextStyle(color: KiteColors.muted, fontSize: 12.5)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: KiteColors.surface2,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: KiteColors.border),
            ),
            child: Text(_myCode,
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    fontSize: 15,
                    color: KiteColors.fg)),
          ),
          const SizedBox(height: 10),
          const Text(
            'Faites-le scanner par la personne en face de vous —\nla conversation s’ouvre directement.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: KiteColors.muted,
                fontSize: 12.5,
                height: 1.45),
          ),
        ],
      ),
    );
  }

  // ---------- Onglet 2 : scanner / saisie ----------

  Widget _scanTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Zone de scan : cadre caméra simulé (capture optique réelle à
          // brancher au transport P2P) ; la saisie de code fonctionne
          // partout, même sans caméra.
          Container(
            height: 190,
            decoration: BoxDecoration(
              color: KiteColors.surface2,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: KiteColors.border),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.qr_code_scanner,
                      size: 44, color: KiteColors.muted.withValues(alpha: 0.6)),
                  const SizedBox(height: 10),
                  const Text('Caméra indisponible ici',
                      style: TextStyle(
                          color: KiteColors.muted, fontSize: 12.5)),
                  const SizedBox(height: 4),
                  const Text('Saisissez le code de votre contact :',
                      style: TextStyle(
                          color: Color(0xFF8A8F98),
                          fontSize: 11.5)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _manual,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _openPeer(_byCode(_manual.text)),
            style: const TextStyle(color: KiteColors.fg, letterSpacing: 1),
            decoration: InputDecoration(
              hintText: 'ex : julien-42',
              hintStyle: const TextStyle(color: KiteColors.muted),
              errorText: _manualError,
              filled: true,
              fillColor: KiteColors.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: KiteColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: KiteColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: KiteColors.accent),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward,
                    color: KiteColors.accent),
                onPressed: () => _openPeer(_byCode(_manual.text)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Radar de pairs : anneaux pulsés (spring) + liste des pairs connus
/// apparaissant en cascade — prêt à recevoir la découverte réseau réelle.
class PeerRadarTab extends StatefulWidget {
  const PeerRadarTab({
    super.key,
    required this.api,
    required this.users,
    required this.onPick,
  });

  final KiteApi api;
  final List<User> users;
  final void Function(User?) onPick;

  @override
  State<PeerRadarTab> createState() => _PeerRadarTabState();
}

class _PeerRadarTabState extends State<PeerRadarTab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  final Set<String> _revealed = {};

  @override
  void initState() {
    super.initState();
    // Les pairs « apparaissent » progressivement (découverte simulée).
    for (var i = 0; i < widget.users.length; i++) {
      Future.delayed(Duration(milliseconds: 500 + i * 550), () {
        if (mounted) setState(() => _revealed.add(widget.users[i].id));
      });
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peers =
        widget.users.where((u) => u.id != widget.api.meId).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          SizedBox(
            width: 200,
            height: 200,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                return CustomPaint(
                  painter: _RadarPainter(
                    t: _pulse.value,
                    count: _revealed.length,
                    accent: KiteColors.accent,
                    border: KiteColors.border,
                    sage: KiteColors.sage,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            peers.isEmpty
                ? 'Recherche de personnes à proximité…'
                : '${_revealed.length} personne(s) détectée(s) autour de vous',
            style: const TextStyle(color: KiteColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          for (final u in peers)
            _revealed.contains(u.id)
                ? _PeerTile(user: u, onPick: widget.onPick)
                : const SizedBox(height: 0),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.user, required this.onPick});

  final User user;
  final void Function(User?) onPick;

  @override
  Widget build(BuildContext context) {
    return MessageEntrance(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: KiteColors.surface2,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              KiteHaptics.tap();
              onPick(user);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor:
                        KiteColors.sage.withValues(alpha: 0.15),
                    child: Text(
                      user.name.isNotEmpty ? user.name[0] : '?',
                      style: const TextStyle(
                          color: KiteColors.sage,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(user.name,
                        style: const TextStyle(
                            color: KiteColors.fg,
                            fontWeight: FontWeight.w600)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: KiteColors.sage.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('présent',
                        style: TextStyle(
                            color: KiteColors.sage, fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.t,
    required this.count,
    required this.accent,
    required this.border,
    required this.sage,
  });

  final double t;
  final int count;
  final Color accent;
  final Color border;
  final Color sage;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2 - 2;

    // Anneaux pulsés : trois vagues déphasées qui s'estompent.
    for (var w = 0; w < 3; w++) {
      final phase = (t + w / 3) % 1.0;
      final r = maxR * phase;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = accent.withValues(alpha: (1 - phase) * 0.45);
      canvas.drawCircle(c, r, paint);
    }

    // Cercles de fond.
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = border;
    canvas.drawCircle(c, maxR * 0.55, bg);
    canvas.drawCircle(c, maxR, bg);

    // Point central (moi).
    canvas.drawCircle(c, 7, Paint()..color = accent);

    // Pairs détectés : positions pseudo-aléatoires stables.
    final rng = Random(42);
    for (var i = 0; i < count; i++) {
      final a = rng.nextDouble() * 2 * pi;
      final r = maxR * (0.35 + 0.5 * rng.nextDouble());
      final p = c + Offset(cos(a) * r, sin(a) * r);
      canvas.drawCircle(p, 5, Paint()..color = sage);
      canvas.drawCircle(
          p, 9, Paint()..color = sage.withValues(alpha: 0.25));
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.t != t || old.count != count;
}
