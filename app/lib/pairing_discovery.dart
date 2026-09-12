import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Découverte de pairs sur le réseau local — 100 % dart:io (UDP), aucun
/// plugin natif.
///
/// Chaque appareil qui ouvre la feuille de jumelage :
///  - écoute le port bien connu [kPairingPort] ;
///  - diffuse périodiquement son annonce JSON {v, id, name, nonce} ;
///  - répond en unicast à toute annonce reçue (les deux côtés se voient).
///
/// Les datagrammes sont limités au réseau local par nature (broadcast) ;
/// l'identité est un nom déclaré par l'appareil, sans secret — c'est un
/// ustensile de rencontre, pas une authentification.
class PairingDiscovery {
  PairingDiscovery._();

  /// Port d'écoute (bind) ; injectable pour les tests.
  static int kPairingPort = 45717;

  /// Destination des annonces (tests : unicast vers le pair factice au
  /// lieu du broadcast). null = broadcast 255.255.255.255.
  static InternetAddress? testAnnounceTo;
  static int? testAnnouncePort;

  static const String _magic = 'KITE1';
  static final InternetAddress _broadcast =
      InternetAddress('255.255.255.255');

  RawDatagramSocket? _socket;
  Timer? _announce;
  final Map<String, DateTime> _lastSeen = {};
  final Map<String, User> _peers = {};
  final _controller = StreamController<List<User>>.broadcast();
  String? _meId;
  String? _meName;

  static PairingDiscovery? _instance;
  static PairingDiscovery get instance => _instance ??= PairingDiscovery._();

  /// Réinitialise le singleton (tests uniquement).
  static void resetForTest() {
    final old = _instance;
    _instance = null;
    old?.dispose();
  }

  /// Flux des pairs actuellement visibles (rafraîchi à chaque événement).
  Stream<List<User>> get peers => _controller.stream;

  List<User> get currentPeers =>
      _peers.values.where((u) => u.id != _meId).toList();

  bool get running => _socket != null;

  /// Démarre l'écoute + les annonces. Retourne false si le réseau local
  /// n'est pas disponible (pas de dégradation silencieuse : la feuille
  /// affiche l'état réel).
  Future<bool> start({required String meId, required String meName}) async {
    if (running) {
      if (_meId != meId) stop();
      return true;
    }
    _meId = meId;
    _meName = meName;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kPairingPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onDatagram);
      _sendAnnounce(); // visibilité immédiate
      _announce = Timer.periodic(const Duration(seconds: 2), (_) {
        _sendAnnounce();
        _expire();
      });
      return true;
    } catch (_) {
      stop();
      return false;
    }
  }

  void stop() {
    _announce?.cancel();
    _announce = null;
    _socket?.close();
    _socket = null;
    _lastSeen.clear();
    _peers.clear();
    if (!_controller.isClosed) _controller.add(const []);
  }

  Future<void> dispose() async {
    stop();
    await _controller.close();
    _instance = null;
  }

  void _onDatagram(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    try {
      final msg = utf8.decode(dg.data);
      if (!msg.startsWith('$_magic ')) return;
      final payload =
          jsonDecode(msg.substring(_magic.length + 1)) as Map<String, dynamic>;
      if (payload['v'] != 1) return;
      final id = payload['id'] as String? ?? '';
      if (id.isEmpty || id == _meId) return; // notre propre annonce
      final name = payload['name'] as String? ?? '';
      if (name.isEmpty) return;
      // Anti-boucle : les deux côtés répondent aux annonces — sans garde,
      // chaque réponse redevenant une annonce, la paire s'appellerait
      // indéfiniment. Annonce déjà vue il y a < 4 s : on actualise la
      // présence SANS répondre.
      final known = _peers.containsKey(id);
      final fresh = known &&
          DateTime.now().difference(_lastSeen[id]!) <
              const Duration(seconds: 4);
      _lastSeen[id] = DateTime.now();
      _peers[id] = User(id: id, name: name);
      if (!known) _controller.add(currentPeers); // nouveau pair visible
      if (!fresh) {
        _sendTo(_announcePayload(), dg.address, dg.port);
      }
    } catch (_) {
      // datagramme malformé : ignoré
    }
  }

  Map<String, dynamic> _announcePayload() =>
      {'v': 1, 'id': _meId, 'name': _meName};

  void _sendAnnounce() {
    if (_meId == null) return;
    final data = utf8.encode('$_magic ${jsonEncode(_announcePayload())}');
    try {
      final target = testAnnounceTo;
      if (target != null) {
        _socket?.send(data, target, testAnnouncePort ?? kPairingPort);
      } else {
        _socket?.send(data, _broadcast, kPairingPort);
      }
    } catch (_) {}
  }

  void _sendTo(Map<String, dynamic> payload, InternetAddress addr, int port) {
    try {
      _socket?.send(utf8.encode('$_magic ${jsonEncode(payload)}'), addr, port);
    } catch (_) {}
  }

  void _expire() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 7));
    final gone = _peers.keys
        .where((id) => (_lastSeen[id] ?? cutoff).isBefore(cutoff))
        .toList();
    if (gone.isEmpty) return;
    for (final id in gone) {
      _peers.remove(id);
      _lastSeen.remove(id);
    }
    _controller.add(currentPeers);
  }

  /// Le pair à qui répondre a besoin de notre code : résout un code
  /// « julien-42 » (id sans préfixe + checksum) contre la liste connue.
  static String shortCode(String userId) {
    final raw = userId.replaceAll(RegExp(r'^u-'), '');
    final sum = raw.codeUnits.fold<int>(0, (a, c) => a + c) % 97;
    return '$raw-${sum.toString().padLeft(2, '0')}';
  }

  /// Resolve d'un code affiché/scanné : cherche d'abord les pairs vus sur
  /// le réseau, puis le store local (contact déjà jumelé).
  User? resolveCode(String code, List<User> knownUsers) {
    final norm = code.trim().toLowerCase();
    if (norm.isEmpty) return null;
    for (final u in _peers.values) {
      if (shortCode(u.id).toLowerCase() == norm) return u;
    }
    for (final u in knownUsers) {
      if (shortCode(u.id).toLowerCase() == norm) return u;
      if (u.id.toLowerCase() == norm || u.id.toLowerCase().endsWith(norm)) {
        return u;
      }
    }
    return null;
  }
}
