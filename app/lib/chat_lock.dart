import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Verrouillage de discussions, persisté localement sur l'appareil (un JSON
/// par app, chemin identique à [LocalStore]/[DraftStore]).
///
/// Le verrou protège l'accès à une conversation sur CET appareil (écran
/// verrouillé, téléphone prêté, regard indiscret) : il est donc
/// volontairement hors-serveur, comme les brouillons. Le code est stocké
/// haché (SHA-256), jamais en clair.
/// Abstraction de l'authentification biométrique (injectable pour les tests).
abstract class BiometricAuthenticator {
  /// true si l'appareil peut proposer la biométrie maintenant.
  Future<bool> isAvailable();

  /// Lance l'invite système (empreinte/face). true si reconnu.
  Future<bool> authenticate(String reason);
}

/// Implémentation réelle via local_auth (Android/iOS/Windows).
class LocalAuthAuthenticator implements BiometricAuthenticator {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      if (!(Platform.isAndroid || Platform.isIOS || Platform.isWindows)) {
        return false;
      }
      if (!await _auth.isDeviceSupported()) return false;
      final kinds = await _auth.getAvailableBiometrics();
      return kinds.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) {
    try {
      return _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        authMessages: const [
          AndroidAuthMessages(signInTitle: 'Déverrouiller la discussion'),
        ],
      );
    } catch (_) {
      return Future<bool>.value(false);
    }
  }
}

/// Clé méta héritée (ancien réglage global) dans kite-chatlock.json ;
/// migrée vers la préférence par conversation au chargement.
const String _legacyBioKey = '_biometrics';

/// Clé méta du verrou d'app (code + préférence biométrique) dans
/// kite-chatlock.json.
const String _appLockKey = '_appLock';

class ChatLockStore extends ChangeNotifier {
  ChatLockStore._();
  static final ChatLockStore instance = ChatLockStore._();

  final Map<String, String> _hashes = {}; // chatId -> sha256(code)

  /// Verrou d'app : code haché (null = désactivé) + biométrie autorisée
  /// + délai de grâce avant re-verrouillage au retour au premier plan.
  String? _appHash;
  bool _appBio = false;
  int _appGrace = 0;

  /// Conversations dont la porte accepte la biométrie (préférence par
  /// conversation, persistée ; la capacité réelle est vérifiée via
  /// local_auth à l'affichage).
  final Set<String> _biometricChats = {};
  File? _file;
  bool _loaded = false;

  /// Conversations déverrouillées dans cette session (jusqu'à verrouillage
  /// manuel ou auto-lock au retour au premier plan).
  final Set<String> _unlocked = {};

  File? get _storeFile {
    if (_file != null) return _file;
    try {
      final env = Platform.environment;
      String base;
      if (Platform.isWindows) {
        base = env['APPDATA'] ?? env['HOME'] ?? Directory.current.path;
      } else if (Platform.isMacOS) {
        base =
            '${env['HOME'] ?? Directory.current.path}/Library/Application Support';
      } else {
        base = env['HOME'] ?? Directory.current.path;
      }
      final dir = Directory('$base/kite');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file = File('${dir.path}${Platform.pathSeparator}kite-chatlock.json');
    } catch (_) {
      return null; // persistance indisponible : mémoire seule
    }
    return _file;
  }

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final f = _storeFile;
    if (f == null || !f.existsSync()) return;
    try {
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      var legacyBio = false;
      raw.forEach((k, v) {
        if (k == _appLockKey) {
          if (v is Map<String, dynamic>) {
            _appHash = v['hash'] as String?;
            _appBio = v['bio'] == true;
            _appGrace = (v['grace'] as num?)?.toInt() ?? 0;
          }
          return;
        }
        if (k == _legacyBioKey) {
          legacyBio = v == true; // ancien réglage global
          return;
        }
        final h = v is Map<String, dynamic> ? v['hash'] as String? : null;
        if (h != null && h.isNotEmpty) {
          _hashes[k] = h;
          if (v['bio'] == true) _biometricChats.add(k);
        }
      });
      // Migration : l'ancien réglage global s'applique à tous les verrous.
      if (legacyBio) _biometricChats.addAll(_hashes.keys);
    } catch (_) {
      // fichier corrompu : on repart de zéro (aucun verrou actif)
    }
  }

  void _flush() {
    final f = _storeFile;
    if (f == null) return;
    try {
      final data = _hashes.map((k, v) => MapEntry(k, <String, Object?>{
            'hash': v,
            if (_biometricChats.contains(k)) 'bio': true,
          }));
      if (_appHash != null) {
        data[_appLockKey] = {'hash': _appHash, 'bio': _appBio, 'grace': _appGrace};
      }
      f.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  static String _hash(String code) =>
      sha256.convert(utf8.encode(code)).toString();

  /// true si un verrou est posé sur cette conversation.
  bool isLocked(String chatId) {
    _ensureLoaded();
    return _hashes.containsKey(chatId);
  }

  /// true si l'utilisateur peut ouvrir la conversation maintenant.
  bool canOpen(String chatId) {
    _ensureLoaded();
    return !_hashes.containsKey(chatId) || _unlocked.contains(chatId);
  }

  /// Pose le verrou avec [code] (4-8 chiffres). Retourne false si un verrou
  /// existe déjà ou si le code est invalide.
  bool setLock(String chatId, String code) {
    _ensureLoaded();
    if (_hashes.containsKey(chatId) || !_valid(code)) return false;
    _hashes[chatId] = _hash(code);
    _unlocked.add(chatId); // posé à l'instant : pas besoin de le retaper
    _flush();
    return true;
  }

  /// Change le code (nécessite l'ancien).
  bool changeCode(String chatId, String oldCode, String newCode) {
    _ensureLoaded();
    if (!_hashes.containsKey(chatId)) return false;
    if (_hashes[chatId] != _hash(oldCode) || !_valid(newCode)) return false;
    _hashes[chatId] = _hash(newCode);
    _flush();
    notifyListeners();
    return true;
  }

  /// Vérifie le code et déverrouille la conversation pour la session.
  bool unlock(String chatId, String code) {
    _ensureLoaded();
    if (_hashes[chatId] != _hash(code)) return false;
    _unlocked.add(chatId);
    notifyListeners();
    return true;
  }

  /// Retire le verrou (nécessite le code).
  bool removeLock(String chatId, String code) {
    _ensureLoaded();
    if (_hashes[chatId] != _hash(code)) return false;
    _hashes.remove(chatId);
    _biometricChats.remove(chatId);
    _unlocked.remove(chatId);
    _flush();
    notifyListeners();
    return true;
  }

  /// Biométrie autorisée pour cette conversation (persisté).
  bool biometricsFor(String chatId) {
    _ensureLoaded();
    return _biometricChats.contains(chatId);
  }

  /// Active/désactive le déverrouillage biométrique d'une conversation.
  /// Sans effet si la conversation n'a pas de verrou.
  void setBiometricsFor(String chatId, bool enabled) {
    _ensureLoaded();
    if (!_hashes.containsKey(chatId)) return;
    if (_biometricChats.contains(chatId) == enabled) return;
    if (enabled) {
      _biometricChats.add(chatId);
    } else {
      _biometricChats.remove(chatId);
    }
    _flush();
    notifyListeners();
  }

  /// Déverrouille après une authentification biométrique réussie (la porte
  /// vérifie au préalable que la biométrie est activée et disponible).
  void unlockBiometric(String chatId) {
    _ensureLoaded();
    if (!_biometricChats.contains(chatId) || !_hashes.containsKey(chatId)) {
      return;
    }
    _unlocked.add(chatId);
    notifyListeners();
  }

  // ---------- Verrou d'app (écran entier) ----------

  /// true si un verrou d'app est posé.
  bool get appLockEnabled {
    _ensureLoaded();
    return _appHash != null;
  }

  /// true si la porte d'app accepte la biométrie (persisté).
  bool get appBiometricsEnabled {
    _ensureLoaded();
    return _appBio;
  }

  /// Pose le verrou d'app avec un code à 4 chiffres. false si déjà posé
  /// ou code invalide.
  bool setAppLock(String code) {
    _ensureLoaded();
    if (_appHash != null || !_valid(code)) return false;
    _appHash = _hash(code);
    _flush();
    notifyListeners();
    return true;
  }

  /// Autorise la biométrie sur la porte d'app (après pose du verrou).
  void setAppBiometrics(bool enabled) {
    _ensureLoaded();
    if (_appHash == null || _appBio == enabled) return;
    _appBio = enabled;
    _flush();
    notifyListeners();
  }

  /// Délai de grâce avant re-verrouillage au retour au premier plan,
  /// en secondes (0 = immédiat). Persisté avec le verrou d'app.
  int get appLockGrace {
    _ensureLoaded();
    return _appGrace;
  }

  /// Définit le délai de grâce (0, 30 ou 60 s). Sans effet si la valeur
  /// n'est pas autorisée.
  void setAppLockGrace(int seconds) {
    _ensureLoaded();
    if (seconds != 0 && seconds != 30 && seconds != 60) return;
    if (_appGrace == seconds) return;
    _appGrace = seconds;
    _flush();
    notifyListeners();
  }

  /// true si l'app doit se re-verrouiller après une pause de [pausedFor]
  /// alors qu'elle a été déverrouillée il y a [unlockedAgo]. Le délai de
  /// grâce remplace l'ancien anti-rebond fixe de 2 s.
  bool shouldRelockApp({required Duration pausedFor, required Duration unlockedAgo}) {
    final grace = Duration(seconds: _appGrace);
    if (pausedFor >= grace) return true;
    // Pause plus courte que la grâce : on ne re-verrouille que si le
    // déverrouillage lui-même est plus ancien que la grâce (anti-abus).
    return unlockedAgo >= grace;
  }

  /// Déverrouille l'app avec le code. false si incorrect.
  bool unlockApp(String code) {
    _ensureLoaded();
    if (_appHash == null) return true;
    if (_appHash != _hash(code)) return false;
    notifyListeners();
    return true;
  }

  /// Marque l'app déverrouillée après succès biométrique (vérifié par la
  /// porte : préférence active + capacité de l'appareil).
  void unlockAppBiometric() {
    _ensureLoaded();
    if (!_appBio || _appHash == null) return;
    notifyListeners();
  }

  /// Retire le verrou d'app (nécessite le code).
  bool removeAppLock(String code) {
    _ensureLoaded();
    if (_appHash == null || _appHash != _hash(code)) return false;
    _appHash = null;
    _appBio = false;
    _appGrace = 0;
    _flush();
    notifyListeners();
    return true;
  }

  /// Referme une conversation déverrouillée (bouton cadenas, app switcher…).
  void lock(String chatId) {
    if (_unlocked.remove(chatId)) notifyListeners();
  }

  /// Auto-lock : au retour au premier plan, toutes les conversations
  /// déverrouillées se referment (comportement WhatsApp).
  void lockAll() {
    if (_unlocked.isEmpty) return;
    _unlocked.clear();
    notifyListeners();
  }

  static bool _valid(String code) {
    if (code.length != 4) return false;
    for (final c in code.runes) {
      if (c < 0x30 || c > 0x39) return false; // chiffres uniquement
    }
    return true;
  }

  /// Test uniquement.
  @visibleForTesting
  void resetForTest({File? file}) {
    _hashes.clear();
    _biometricChats.clear();
    _unlocked.clear();
    _appHash = null;
    _appBio = false;
    _file = file;
    _loaded = false;
  }
}

/// Porte d'entrée d'une conversation verrouillée : pad de code PIN.
///
/// Deux modes :
/// - [LockGateMode.setup] : saisie puis confirmation d'un nouveau code
///   (pose du verrou sur la conversation).
/// - [LockGateMode.unlock] : déverrouillage d'une conversation déjà
///   verrouillée (code unique, tentatives illimitées).
///
/// Le contenu de la conversation n'est JAMAIS construit sous la porte :
/// un placeholder masqué est affiché à sa place (aucune fuite dans
/// l'arbre de widgets, les captures d'écran ou les recettes de tests).
class LockGate extends StatefulWidget {
  const LockGate({
    super.key,
    required this.chatId,
    required this.chatName,
    required this.mode,
    required this.onDone,
    this.authenticator,
  });

  final String chatId;
  final String chatName;
  final LockGateMode mode;
  final VoidCallback onDone;

  /// Injecté par les tests ; [LocalAuthAuthenticator] en production.
  final BiometricAuthenticator? authenticator;

  @override
  State<LockGate> createState() => _LockGateState();
}

enum LockGateMode { setup, unlock }

class _LockGateState extends State<LockGate> {
  String _code = '';
  String? _firstCode; // setup : première saisie
  String _error = '';

  late final BiometricAuthenticator _bio;
  bool _bioAvailable = false;
  bool _bioPromptOpen = false;

  @override
  void initState() {
    super.initState();
    _bio = widget.authenticator ?? LocalAuthAuthenticator();
    _initBiometrics();
  }

  Future<void> _initBiometrics() async {
    final store = ChatLockStore.instance;
    final wanted = store.biometricsFor(widget.chatId) ||
        widget.mode == LockGateMode.setup;
    if (!wanted) return;
    final ok = await _bio.isAvailable();
    if (!mounted) return;
    setState(() => _bioAvailable = ok);
    // Déverrouillage : invite biométrique automatique à l'ouverture.
    if (ok &&
        store.biometricsFor(widget.chatId) &&
        widget.mode == LockGateMode.unlock) {
      await _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_bioPromptOpen) return;
    _bioPromptOpen = true;
    try {
      final ok = await _bio.authenticate(
          'Déverrouillez la discussion avec la biométrie');
      if (!mounted) return;
      if (ok) {
        ChatLockStore.instance.unlockBiometric(widget.chatId);
        widget.onDone();
      } else {
        setState(() =>
            _error = 'Biométrie non reconnue — utilisez le code PIN');
      }
    } finally {
      _bioPromptOpen = false;
    }
  }

  void _push(String digit) {
    if (_code.length >= 4) return;
    setState(() {
      _code += digit;
      _error = '';
    });
    if (_code.length == 4) _submit();
  }

  void _backspace() {
    if (_code.isEmpty) return;
    setState(() {
      _code = _code.substring(0, _code.length - 1);
      _error = '';
    });
  }

  Future<void> _submit() async {
    final store = ChatLockStore.instance;
    if (widget.mode == LockGateMode.setup) {
      if (_firstCode == null) {
        // Étape 1 : mémoriser, faire confirmer.
        setState(() {
          _firstCode = _code;
          _code = '';
        });
        return;
      }
      if (_code != _firstCode) {
        // Confirmation différente : reprendre à zéro.
        setState(() {
          _firstCode = null;
          _code = '';
          _error = 'Les codes ne correspondent pas, recommencez';
        });
        return;
      }
      final ok = store.setLock(widget.chatId, _code);
      if (!ok) {
        setState(() {
          _code = '';
          _error = 'Impossible de poser le verrou';
        });
        return;
      }
      // Proposer la biométrie si l'appareil le permet (une seule demande).
      if (_bioAvailable && !store.biometricsFor(widget.chatId)) {
        final useBio = await showDialog<bool>(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            backgroundColor: KiteColors.surface,
            title: const Text('Déverrouillage biométrique',
                style: TextStyle(color: KiteColors.fg)),
            content: const Text(
                'Utiliser l’empreinte ou le visage pour ouvrir cette '
                'discussion ? Le code reste la solution de secours.',
                style: TextStyle(color: KiteColors.muted)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('Plus tard'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text('Activer'),
              ),
            ],
          ),
        );
        if (useBio == true) store.setBiometricsFor(widget.chatId, true);
      }
      if (mounted) widget.onDone();
      return;
    }
    // Mode unlock.
    if (store.unlock(widget.chatId, _code)) {
      widget.onDone();
    } else {
      setState(() {
        _code = '';
        _error = 'Code incorrect';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSetup = widget.mode == LockGateMode.setup;
    final title = isSetup
        ? (_firstCode == null
            ? 'Choisissez un code à 4 chiffres'
            : 'Confirmez le code')
        : 'Discussion verrouillée';
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline,
                  size: 44, color: KiteColors.accent),
              const SizedBox(height: 12),
              Text(
                widget.chatName,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(title,
                  style:
                      const TextStyle(color: KiteColors.muted, fontSize: 13)),
              const SizedBox(height: 18),
              // Points du code saisi.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 4; i++)
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _code.length
                            ? KiteColors.accent
                            : Colors.transparent,
                        border: Border.all(color: KiteColors.muted),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 18,
                child: Text(_error,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 12.5)),
              ),
              _Keypad(onDigit: _push, onBackspace: _backspace),
              if (!isSetup &&
                  _bioAvailable &&
                  ChatLockStore.instance.biometricsFor(widget.chatId))
                TextButton.icon(
                  onPressed: _bioPromptOpen ? null : _authenticate,
                  icon: const Icon(Icons.fingerprint,
                      size: 26, color: KiteColors.accent),
                  label: const Text('Utiliser la biométrie',
                      style: TextStyle(color: KiteColors.accent)),
                ),
              if (!isSetup)
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Quitter la conversation'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _KeypadCallback = void Function(String digit);

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace});

  final _KeypadCallback onDigit;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del'],
    ];
    return SizedBox(
      width: 240,
      child: Column(
        children: [
          for (final row in rows)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final key in row)
                  SizedBox(
                    width: 76,
                    height: 62,
                    child: key.isEmpty
                        ? const SizedBox.expand()
                        : Padding(
                            padding: const EdgeInsets.all(4),
                            child: key == 'del'
                                ? IconButton(
                                    icon: const Icon(Icons.backspace_outlined,
                                        size: 20),
                                    onPressed: onBackspace,
                                  )
                                : InkResponse(
                                    onTap: () => onDigit(key),
                                    radius: 28,
                                    child: Center(
                                      child: Text(key,
                                          style: const TextStyle(
                                              fontSize: 21,
                                              fontWeight: FontWeight.w500)),
                                    ),
                                  ),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Porte d'entrée de l'app entière : pad de code PIN (avec biométrie
/// optionnelle). Posée au démarrage et à chaque retour au premier plan
/// tant que le verrou d'app est actif.
///
/// Deux modes :
/// - [AppLockGateMode.setup] : saisie puis confirmation du code, proposition
///   biométrique si l'appareil le permet.
/// - [AppLockGateMode.unlock] : déverrouillage (code ou biométrie).
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.mode,
    required this.onDone,
    this.authenticator,
  });

  final AppLockGateMode mode;
  final VoidCallback onDone;

  /// Injecté par les tests ; [LocalAuthAuthenticator] en production.
  final BiometricAuthenticator? authenticator;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

enum AppLockGateMode { setup, unlock }

class _AppLockGateState extends State<AppLockGate> {
  String _code = '';
  String? _firstCode; // setup : première saisie
  String _error = '';

  late final BiometricAuthenticator _bio;
  bool _bioAvailable = false;
  bool _bioPromptOpen = false;

  @override
  void initState() {
    super.initState();
    _bio = widget.authenticator ?? LocalAuthAuthenticator();
    _initBiometrics();
  }

  Future<void> _initBiometrics() async {
    final store = ChatLockStore.instance;
    final wanted =
        store.appBiometricsEnabled || widget.mode == AppLockGateMode.setup;
    if (!wanted) return;
    final ok = await _bio.isAvailable();
    if (!mounted) return;
    setState(() => _bioAvailable = ok);
    if (ok &&
        store.appBiometricsEnabled &&
        widget.mode == AppLockGateMode.unlock) {
      await _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_bioPromptOpen) return;
    _bioPromptOpen = true;
    try {
      final ok =
          await _bio.authenticate('Déverrouillez Kite avec la biométrie');
      if (!mounted) return;
      if (ok) {
        ChatLockStore.instance.unlockAppBiometric();
        widget.onDone();
      } else {
        setState(() => _error = 'Biométrie non reconnue — utilisez le code');
      }
    } finally {
      _bioPromptOpen = false;
    }
  }

  void _push(String digit) {
    if (_code.length >= 4) return;
    setState(() {
      _code += digit;
      _error = '';
    });
    if (_code.length == 4) _submit();
  }

  void _backspace() {
    if (_code.isEmpty) return;
    setState(() {
      _code = _code.substring(0, _code.length - 1);
      _error = '';
    });
  }

  Future<void> _submit() async {
    final store = ChatLockStore.instance;
    if (widget.mode == AppLockGateMode.setup) {
      if (_firstCode == null) {
        setState(() {
          _firstCode = _code;
          _code = '';
        });
        return;
      }
      if (_code != _firstCode) {
        setState(() {
          _firstCode = null;
          _code = '';
          _error = 'Les codes ne correspondent pas, recommencez';
        });
        return;
      }
      final ok = store.setAppLock(_code);
      if (!ok) {
        setState(() {
          _code = '';
          _error = 'Impossible de poser le verrou';
        });
        return;
      }
      if (_bioAvailable && !store.appBiometricsEnabled) {
        final useBio = await showDialog<bool>(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            backgroundColor: KiteColors.surface,
            title: const Text('Déverrouillage biométrique',
                style: TextStyle(color: KiteColors.fg)),
            content: const Text(
                "Utiliser l'empreinte ou le visage pour ouvrir Kite ? "
                'Le code reste la solution de secours.',
                style: TextStyle(color: KiteColors.muted)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('Plus tard'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text('Activer'),
              ),
            ],
          ),
        );
        if (useBio == true) store.setAppBiometrics(true);
      }
      if (mounted) widget.onDone();
      return;
    }
    // Mode unlock.
    if (store.unlockApp(_code)) {
      widget.onDone();
    } else {
      setState(() {
        _code = '';
        _error = 'Code incorrect';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSetup = widget.mode == AppLockGateMode.setup;
    final title = isSetup
        ? (_firstCode == null
            ? 'Choisissez un code à 4 chiffres'
            : 'Confirmez le code')
        : 'Kite verrouillé';
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shield_outlined,
                  size: 44, color: KiteColors.accent),
              const SizedBox(height: 12),
              const Text('Kite',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(title,
                  style:
                      const TextStyle(color: KiteColors.muted, fontSize: 13)),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 4; i++)
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _code.length
                            ? KiteColors.accent
                            : Colors.transparent,
                        border: Border.all(color: KiteColors.muted),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 18,
                child: Text(_error,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 12.5)),
              ),
              _Keypad(onDigit: _push, onBackspace: _backspace),
              if (!isSetup &&
                  _bioAvailable &&
                  ChatLockStore.instance.appBiometricsEnabled)
                TextButton.icon(
                  onPressed: _bioPromptOpen ? null : _authenticate,
                  icon: const Icon(Icons.fingerprint,
                      size: 26, color: KiteColors.accent),
                  label: const Text('Utiliser la biométrie',
                      style: TextStyle(color: KiteColors.accent)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
