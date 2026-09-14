import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Carte de localisation : rend une vraie tuile OpenStreetMap quand le
/// réseau est joignable, repli honnête sinon. La position est ouvrable via
/// un lien `geo:` (décodé par l'OS) — aucun service de cartographie propriétaire.
class KiteLocationMap extends StatefulWidget {
  const KiteLocationMap({
    super.key,
    required this.latitude,
    required this.longitude,
    this.width = 220,
    this.height = 120,
    this.zoom = 15,
  });

  final double latitude;
  final double longitude;
  final double width;
  final double height;
  final int zoom;

  /// Lien geo: standard (RFC 5870) — décodé par Android/iOS.
  String get geoUri => 'geo:$latitude,$longitude?q=$latitude,$longitude';

  /// Lien web de secours (navigateur).
  String get webUri =>
      'https://www.openstreetmap.org/?mlat=$latitude&mlon=$longitude#map=$zoom/$latitude/$longitude';

  /// Tuile OSM englobant la position (schéma XYZ standard).
  (int, int) tileFor(double lat, double lon, int z) {
    final n = 1 << z;
    final x = ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
    final r = lat * math.pi / 180;
    final y = ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
        .floor()
        .clamp(0, n - 1);
    return (x, y);
  }

  @override
  State<KiteLocationMap> createState() => _KiteLocationMapState();
}

class _KiteLocationMapState extends State<KiteLocationMap> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _loaded = false;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(covariant KiteLocationMap old) {
    super.didUpdateWidget(old);
    if (old.latitude != widget.latitude ||
        old.longitude != widget.longitude ||
        old.zoom != widget.zoom) {
      _loaded = false;
      _failed = false;
      _listen();
    }
  }

  void _listen() {
    final (x, y) = widget.tileFor(widget.latitude, widget.longitude, widget.zoom);
    final url =
        'https://tile.openstreetmap.org/${widget.zoom}/$x/$y.png';
    final stream = Image.network(url, gaplessPlayback: true)
        .image
        .resolve(createLocalImageConfiguration(context));
    _stream?.removeListener(_listener!);
    _listener = ImageStreamListener(
      (image, _) => mounted ? setState(() => _loaded = true) : null,
      onError: (_, __) => mounted ? setState(() => _failed = true) : null,
    );
    stream.addListener(_listener!);
    _stream = stream;
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
    super.dispose();
  }

  Future<void> _open() async {
    // geo: est décodé par l'OS (plans natifs). Repli navigateur sinon.
    final geo = Uri.parse(widget.geoUri);
    if (!await launchUrl(geo, mode: LaunchMode.externalNonBrowserApplication)) {
      await launchUrl(Uri.parse(widget.webUri), mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Container(
        width: widget.width,
        height: widget.height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: KiteColors.border),
        ),
        child: _failed || (!_loaded && _failed)
            ? _offline(context)
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (_loaded)
                    Image.network(
                      'https://tile.openstreetmap.org/${widget.zoom}/${widget.tileFor(widget.latitude, widget.longitude, widget.zoom).$1}/${widget.tileFor(widget.latitude, widget.longitude, widget.zoom).$2}.png',
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => _offline(context),
                    )
                  else
                    const ColoredBox(color: Color(0x14202937)),
                  Center(
                    child: Icon(Icons.location_on,
                        size: 34,
                        color: _loaded
                            ? KiteColors.accent
                            : KiteColors.muted.withValues(alpha: 0.6)),
                  ),
                ],
              ),
      ),
    );
  }

  /// Repli hors-ligne : pas de fausse carte, un état clair + le lien ouvert.
  Widget _offline(BuildContext context) {
    return ColoredBox(
      color: const Color(0x14202937),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off, size: 26, color: KiteColors.muted),
          const SizedBox(height: 4),
          Text('Carte indisponible hors ligne — appuyer pour ouvrir',
              textAlign: TextAlign.center,
              style: TextStyle(color: KiteColors.muted, fontSize: 10.5)),
        ],
      ),
    );
  }
}
