import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/glass_panel.dart';

/// Live partner location on the dashboard. Shows an OpenStreetMap (no API key)
/// with the partner's marker that animates to each new fix, "updated Xs ago",
/// and the distance between you. When the partner stops sharing it shows a
/// "paused" state — never a stale pin presented as live.
class PartnerLocationCard extends StatefulWidget {
  const PartnerLocationCard({
    super.key,
    required this.partner,
    required this.partnerName,
    this.myLat,
    this.myLon,
  });

  final Presence? partner;
  final String partnerName;
  final double? myLat;
  final double? myLon;

  @override
  State<PartnerLocationCard> createState() => _PartnerLocationCardState();
}

class _PartnerLocationCardState extends State<PartnerLocationCard> {
  final _map = MapController();

  @override
  void didUpdateWidget(PartnerLocationCard old) {
    super.didUpdateWidget(old);
    final p = widget.partner;
    if (p != null && p.isSharingLive) {
      final moved = old.partner?.latitude != p.latitude ||
          old.partner?.longitude != p.longitude;
      if (moved) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            _map.move(LatLng(p.latitude!, p.longitude!), _map.camera.zoom);
          } catch (_) {}
        });
      }
    }
  }

  void _recenter() {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) return;
    try {
      _map.move(LatLng(p.latitude!, p.longitude!), 14);
    } catch (_) {}
  }

  String _agoText(DateTime? at) {
    if (at == null) return 'live';
    final secs = DateTime.now().difference(at).inSeconds;
    if (secs < 15) return 'just now';
    if (secs < 60) return '${secs}s ago';
    final mins = secs ~/ 60;
    if (mins < 60) return '${mins}m ago';
    return '${mins ~/ 60}h ago';
  }

  String? _distanceText() {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) return null;
    if (widget.myLat == null || widget.myLon == null) return null;
    if (p.latitude == null || p.longitude == null) return null;
    final m = const Distance().as(
      LengthUnit.Meter,
      LatLng(widget.myLat!, widget.myLon!),
      LatLng(p.latitude!, p.longitude!),
    );
    if (m < 950) return '${m.round()} m apart';
    final km = m / 1000;
    return '${NumberFormat.decimalPattern().format(km.round())} km apart';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) {
      return GlassPanel(
        child: Row(
          children: [
            const Icon(Icons.location_off_outlined,
                color: MilesColors.taupe, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "${widget.partnerName} isn't sharing location right now",
                style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final point = LatLng(p.latitude!, p.longitude!);
    final dist = _distanceText();

    return GlassPanel(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.place, color: MilesColors.blush, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.partnerName} · ${_agoText(p.locationUpdatedAt)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.my_location,
                        color: MilesColors.gilt, size: 20),
                    onPressed: _recenter,
                    tooltip: 'Recenter',
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 190,
              child: FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: point,
                  initialZoom: 13,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.miles.miles',
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: point,
                        width: 46,
                        height: 46,
                        child: _AvatarPin(name: widget.partnerName),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (dist != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Row(
                  children: [
                    const Icon(Icons.favorite,
                        color: MilesColors.blush, size: 14),
                    const SizedBox(width: 8),
                    Text(dist,
                        style: const TextStyle(
                            color: MilesColors.cream50, fontSize: 13)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvatarPin extends StatelessWidget {
  const _AvatarPin({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: MilesColors.blush,
        border: Border.all(color: MilesColors.cream50, width: 2),
        boxShadow: [
          BoxShadow(
              color: MilesColors.blush.withValues(alpha: 0.6), blurRadius: 12),
        ],
      ),
      child: Center(
        child: Text(initial,
            style: const TextStyle(
                color: MilesColors.cream50,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
      ),
    );
  }
}
